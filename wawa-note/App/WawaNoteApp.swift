import EventKit
import LocalAuthentication
import SwiftData
import SwiftUI
import UserNotifications
import WawaNoteCore

@main
struct WawaNoteApp: App {
  private let modelContainer: ModelContainer
  private let recordingCoordinator: RecordingCoordinator
  private let calendarSyncService: CalendarSyncService
  private let sharedEventStore: EKEventStore

  private let ingestionState: ProjectIngestionState
  private let contentPipeline: ContentPipelineService
  private let ingestionPipeline: ProjectIngestionPipeline
  private let processingQueue: ProcessingQueueService

  @StateObject private var biometricGate = BiometricGateService()
  private let notificationTokens = NotificationTokens()

  init() {
    let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let schema = Schema([
      AIProviderConfigModel.self,
      KnowledgeItem.self,
      Folder.self,
      Annotation.self,
      Project.self,
      TaskItem.self,
      Person.self,
      GraphEdge.self,
      Entity.self,
      AgentSuggestion.self,
      QueueEntry.self,
      ProjectFrame.self,
      ChangeRecord.self,
      ProjectSnapshot.self,
      ProjectDerivedItem.self,
    ])
    if isTesting {
      // In-memory store for tests — no disk I/O, fast setup
      let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      modelContainer = try! ModelContainer(for: schema, configurations: config)
    } else {
      modelContainer = Self.createModelContainer(schema: schema)
    }

    ingestionState = ProjectIngestionState()
    ingestionPipeline = ProjectIngestionPipeline(ingestionState: ingestionState)
    contentPipeline = ContentPipelineService(
      ingestionPipeline: ingestionPipeline, ingestionState: ingestionState,
      modelContainer: modelContainer)
    processingQueue = ProcessingQueueService()
    processingQueue.setPipeline(contentPipeline)

    let coordinator = RecordingCoordinator(modelContainer: modelContainer)
    coordinator.contentPipeline = contentPipeline
    coordinator.processingQueue = processingQueue
    recordingCoordinator = coordinator

    sharedEventStore = EKEventStore()
    calendarSyncService = CalendarSyncService(eventStore: sharedEventStore)

    // Restore anarlog sync bookmark and trigger initial scan
    let syncSvc = AnarlogSyncService()
    syncSvc.modelContainer = modelContainer
    if syncSvc.hasWatchedFolder {
      Task { @MainActor in
        await syncSvc.scanAndImport()
      }
    }

    // Run one-time data migrations
    let migrationContext = ModelContext(modelContainer)
    KnowledgeItemService.migrateMeetingToAudio(context: migrationContext)
    ProjectService.migrateProjectColors(context: migrationContext)
    ProjectService.migrateFieldProvenance(context: migrationContext)
    ProjectService.migrateToProjectDerivedItems(context: migrationContext)

    // Setup notifications
    setupNotifications()

    // Initialize persistent file logging (survives crashes)
    let fileLog = FileLogService.shared

    // Clean up any recordings abandoned by a previous crash or force-quit
    coordinator.cleanupOrphanedRecordings()

    // Request location permission early so it's ready when recording starts
    LocationContextSensor().requestPermission()

    if fileLog.previousSessionCrashed {
      AppLog.warn(
        "general",
        "⚠️ Previous session ended abnormally — crash log available in Settings > Debug Logs")
    }

    // Attempt recovery from audio interruptions when app returns to foreground
    notificationTokens.tokens.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { _ in
        AppLog.event("general", "App will enter foreground")
        coordinator.onAppForeground()
      }
    )

    // Revalidate automation config when providers change (add/remove/switch).
    // This cleans up stale model references left behind by deleted providers.
    let container = modelContainer  // capture by value for escaping closure
    notificationTokens.tokens.append(
      NotificationCenter.default.addObserver(
        forName: .activeProviderChanged,
        object: nil,
        queue: .main
      ) { _ in
        AutomationSettings.shared.revalidateAutomationConfig(context: ModelContext(container))
      }
    )

    // Mark clean exit on normal termination
    notificationTokens.tokens.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.willTerminateNotification,
        object: nil,
        queue: .main
      ) { _ in
        AppLog.event("general", "App will terminate — marking clean exit")
        fileLog.markCleanExit()
      }
    )

    // Periodic heartbeat — clears crash sentinel every 30s while app is running
    notificationTokens.tokens.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { _ in
        fileLog.heartbeat()
      }
    )

    notificationTokens.tokens.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { _ in
        AppLog.event("general", "App did enter background")
      }
    )
  }

  // MARK: - Notifications & Badge

  private func setupNotifications() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      AppLog.general.info("Notification permission: \(granted ? "granted" : "denied")")
    }
  }

  // MARK: - Resilient ModelContainer

  /// Creates a ModelContainer with recovery from incompatible store migrations.
  /// If the on-disk store cannot be loaded (schema change, corruption, etc.),
  /// the old store is deleted and a fresh container is created automatically.
  private static func createModelContainer(schema: Schema) -> ModelContainer {
    // One-time migration: if the App Group database doesn't exist yet but
    // the legacy default.store does, copy it to the shared container so
    // existing data (providers, projects, items) is preserved.
    migrateLegacyStoreIfNeeded()
    let config = ModelConfiguration(schema: schema, url: SharedContainer.databaseURL)
    return createModelContainer(schema: schema, config: config)
  }

  /// Copies legacy default.store (from default SwiftData location) to the
  /// App Group shared container as WawaNote.sqlite. Runs once — when the
  /// new store doesn't exist but the legacy store does.
  ///
  /// Background: commit 1c9a0ab switched the database URL from the default
  /// location to the App Group without data migration. Users who had data
  /// in the old location saw all providers/items disappear because the app
  /// opened a new empty database. This migration preserves that data.
  private static func migrateLegacyStoreIfNeeded() {
    let newURL = SharedContainer.databaseURL

    // New store already exists — migration already done or app is fresh
    guard !FileManager.default.fileExists(atPath: newURL.path) else { return }

    guard
      let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }

    let legacyURL = appSupport.appendingPathComponent("default.store")

    // No legacy data to migrate — fresh install
    guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

    AppLog.general.info("🔄 Migrating legacy database from \(legacyURL.path) to \(newURL.path)")

    // Ensure parent directory exists in App Group container
    let newDir = newURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)

    // Copy store file + WAL companions
    // legacy: default.store, default.store-shm, default.store-wal
    // new:     WawaNote.sqlite, WawaNote.sqlite-shm, WawaNote.sqlite-wal
    let companions = ["", "-shm", "-wal"]
    for suffix in companions {
      let sourceURL = appSupport.appendingPathComponent("default.store" + suffix)
      guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

      let destFileName = "WawaNote.sqlite" + suffix
      let destURL = newDir.appendingPathComponent(destFileName)
      do {
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        AppLog.general.info("✅ Migrated default.store\(suffix) → \(destFileName)")
      } catch {
        AppLog.warn("general", "⚠️ Failed to migrate default.store\(suffix): \(error)")
      }
    }

    AppLog.general.info("✅ Legacy database migration complete")
  }

  private static func createModelContainer(schema: Schema, config: ModelConfiguration)
    -> ModelContainer
  {
    do {
      return try ModelContainer(for: schema, configurations: config)
    } catch {
      AppLog.warn("general", "⚠️ ModelContainer load failed — recreating store. Error: \(error)")

      // Save a backup before destroying, so data can be recovered manually.
      Self.backupStoreBeforeDestroy()

      // Delete stores in all possible locations (app container + App Group)
      Self.destroyAllStores()

      // Retry with fresh store at the same App Group URL
      let freshConfig = ModelConfiguration(schema: schema, url: SharedContainer.databaseURL)
      do {
        return try ModelContainer(for: schema, configurations: freshConfig)
      } catch {
        fatalError("Could not create ModelContainer after store recreation: \(error)")
      }
    }
  }

  /// Saves a timestamped backup of the current database before it gets destroyed.
  /// Backup goes to <AppGroup>/DatabaseBackups/<timestamp>/ so the user or support
  /// can recover data manually if the automatic recovery was a false positive.
  private static func backupStoreBeforeDestroy() {
    guard
      let groupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: SharedContainer.appGroupIdentifier)
    else { return }

    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let backupDir = groupURL.appendingPathComponent(
      "DatabaseBackups/\(timestamp)", isDirectory: true)
    try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

    let storeNames = ["WawaNote.sqlite", "default.store"]
    let companions = ["", "-shm", "-wal"]

    // Search both the App Group root and the app container
    var searchDirs: [URL] = [groupURL]
    if let appSupport = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    {
      searchDirs.append(appSupport)
    }

    var backedUp = 0
    for dir in searchDirs {
      for name in storeNames {
        for suffix in companions {
          let source = dir.appendingPathComponent(name + suffix)
          guard FileManager.default.fileExists(atPath: source.path) else { continue }
          let dest = backupDir.appendingPathComponent(name + suffix)
          do {
            try FileManager.default.copyItem(at: source, to: dest)
            backedUp += 1
          } catch {
            AppLog.warn("general", "⚠️ Backup failed for \(name + suffix): \(error)")
          }
        }
      }
    }

    if backedUp > 0 {
      AppLog.general.info("📦 Database backup saved to \(backupDir.path) (\(backedUp) files)")
    }
  }

  /// Deletes store files from both the app container and App Group container,
  /// covering both legacy (default.store) and current (WawaNote.sqlite) names.
  private static func destroyAllStores() {
    var searchDirs: [URL] = []

    // App container Application Support
    if let appSupport = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    {
      searchDirs.append(appSupport)
    }

    // App Group container — root (where WawaNote.sqlite lives)
    if let groupURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroupIdentifier)
    {
      searchDirs.append(groupURL)
      // Also check Library/Application Support inside the group (legacy location)
      searchDirs.append(groupURL.appendingPathComponent("Library/Application Support"))
    }

    // Destroy both legacy and current store names in every searched directory
    let storeNames = ["default.store", "WawaNote.sqlite"]
    for dir in searchDirs {
      for name in storeNames {
        Self.destroyStore(at: dir.appendingPathComponent(name))
      }
    }
  }

  /// Deletes all files associated with a Core Data / SwiftData SQLite store.
  /// SwiftData uses `.store` extension; Core Data uses `.sqlite`.
  /// We handle both and remove the store file, -shm, and -wal companions.
  private static func destroyStore(at url: URL) {
    // The store URL points to e.g. .../default.store or .../default.sqlite
    // Companion files: default.store-shm, default.store-wal
    let storeDir = url.deletingLastPathComponent()
    let storeFileName = url.lastPathComponent  // "default.store"

    let companions = [
      storeFileName,  // default.store
      storeFileName + "-shm",  // default.store-shm
      storeFileName + "-wal",  // default.store-wal
    ]

    for fileName in companions {
      let fileURL = storeDir.appendingPathComponent(fileName)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try? FileManager.default.removeItem(at: fileURL)
        AppLog.general.info("Removed stale store file: \(fileName)")
      }
    }
  }

  static func updateAppBadge(modelContext: ModelContext? = nil) {
    Task { @MainActor in
      guard let ctx = modelContext else { return }
      do {
        let allItems = try ctx.fetch(FetchDescriptor<KnowledgeItem>())
        // Exclude trash items — matches InboxView.needsReviewCount logic
        let trashFolderID = (try? TrashService(context: ctx).trashFolder())?.id
        let inboxCount = allItems.filter { item in
          item.inboxDate != nil && (trashFolderID == nil || item.folderID != trashFolderID)
        }.count
        try? await UNUserNotificationCenter.current().setBadgeCount(inboxCount)
      } catch {
        AppLog.warn("general", "Failed to update app badge: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Body

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(biometricGate)
    }
    .modelContainer(modelContainer)
    .environmentObject(recordingCoordinator)
    .environmentObject(calendarSyncService)
    .environmentObject(ingestionState)
    .environmentObject(contentPipeline)
    .environmentObject(ingestionPipeline)
    .environmentObject(processingQueue)
  }
}

// MARK: - Biometric Gate

@MainActor
final class BiometricGateService: ObservableObject {
  private static let keychainIdentifier = "com.wawa-note.biometric-gate"

  @Published var isAuthenticated = false
  @Published var isEnabled: Bool {
    didSet {
      if isEnabled {
        try? SecureKeyStore().saveAPIKey("1", for: Self.keychainIdentifier)
      } else {
        try? SecureKeyStore().deleteAPIKey(for: Self.keychainIdentifier)
      }
    }
  }

  init() {
    self.isEnabled = (try? SecureKeyStore().loadAPIKey(for: Self.keychainIdentifier)) == "1"
  }

  var biometryType: LABiometryType {
    let ctx = LAContext()
    var error: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      return .none
    }
    return ctx.biometryType
  }

  var biometryName: String {
    switch biometryType {
    case .faceID: return "Face ID"
    case .touchID: return "Touch ID"
    default: return "Biometrics"
    }
  }

  func authenticate() async -> Bool {
    guard isEnabled else { return true }
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Cancel"
    do {
      let ok = try await ctx.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: "Unlock Wawa Note to access your knowledge workspace.")
      if ok { isAuthenticated = true }
      return ok
    } catch {
      return false
    }
  }
}

/// Reference-type container for NotificationCenter observer tokens.
/// Because WawaNoteApp is a struct (SwiftUI App), captured closures
/// cannot mutate a stored array property — they capture a copy.
/// Wrapping in a class allows the closure callbacks to append tokens.
private final class NotificationTokens {
  var tokens: [NSObjectProtocol] = []
}
