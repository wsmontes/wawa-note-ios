import EventKit
import LocalAuthentication
import SwiftData
import SwiftUI
import UserNotifications
import WawaNoteCore

// Related JIRA: KAN-70, KAN-533, KAN-534, KAN-535, KAN-543

@main
struct WawaNoteApp: App {
  private let modelContainer: ModelContainer
  private let recordingCoordinator: RecordingCoordinator
  private let calendarSyncService: CalendarSyncService
  private let sharedEventStore: EKEventStore

  private let contentPipeline: ContentPipelineService
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
      modelContainer = DatabaseManager.createModelContainer(schema: schema)
    }

    contentPipeline = ContentPipelineService(modelContainer: modelContainer)
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
    AIProviderConfigModel.migrateBundledLocalProviderTypes(context: migrationContext)

    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--screenshot-demo") {
        ScreenshotDemoData.seedIfNeeded(context: migrationContext)
      }
    #endif

    // Apply file protection to the shared database
    SharedContainer.ensureProtection()

    // Initialize persistent file logging (survives crashes)
    let fileLog = FileLogService.shared

    // Clean up any recordings abandoned by a previous crash or force-quit
    coordinator.cleanupOrphanedRecordings()

    if fileLog.previousSessionCrashed {
      AppLog.warn(
        "general",
        "⚠️ Previous session ended abnormally — crash log available in Settings > Debug Logs")
    }

    // DEBUG: Auto-transcribe stuck recorded/failed items on launch.
    // Finds items with status .recorded or .failed that have audio and enqueues them.
    let queue = processingQueue
    let mc = modelContainer
    Task { @MainActor in
      let ctx = ModelContext(mc)
      let recordedDescriptor = FetchDescriptor<KnowledgeItem>(
        predicate: #Predicate { $0.statusRaw == "recorded" && $0.audioFileRelativePath != nil }
      )
      let failedDescriptor = FetchDescriptor<KnowledgeItem>(
        predicate: #Predicate { $0.statusRaw == "failed" && $0.audioFileRelativePath != nil }
      )
      let recordedItems = (try? ctx.fetch(recordedDescriptor)) ?? []
      let failedItems = (try? ctx.fetch(failedDescriptor)) ?? []
      let stuckItems = recordedItems + failedItems
      if !stuckItems.isEmpty {
        AppLog.general.info(
          "🚀 Auto-transcribe: found \(stuckItems.count) item(s) to transcribe (recorded=\(recordedItems.count) failed=\(failedItems.count))"
        )
        for item in stuckItems {
          let durStr =
            item.durationSeconds.map { "\(Int($0))s" } ?? "unknown"
          AppLog.general.info(
            "🚀 Auto-transcribe: enqueuing '\(item.title)' (id=\(item.id.uuidString.prefix(8))) duration=\(durStr) status=\(item.statusRaw)"
          )
          // Reset failed items to recorded so the pipeline picks them up
          if item.statusRaw == "failed" {
            item.status = .recorded
            item.lastErrorRaw = nil
          }
          _ = queue.enqueue(itemID: item.id, trigger: .directUserAction, maxRetries: 5)
        }
      }
    }

    // Attempt recovery from audio interruptions when app returns to foreground
    notificationTokens.tokens.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { @MainActor in
          AppLog.event("general", "App will enter foreground")
          coordinator.onAppForeground()
        }
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

  // MARK: - Badge

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
      Group {
        #if DEBUG
          ScreenshotDemoRootView()
        #else
          ContentView()
        #endif
      }
      .environmentObject(biometricGate)
    }
    .modelContainer(modelContainer)
    .environmentObject(recordingCoordinator)
    .environmentObject(calendarSyncService)
    .environmentObject(contentPipeline)
    .environmentObject(processingQueue)
  }
}

#if DEBUG
  private struct ScreenshotDemoRootView: View {
    @Query(sort: \KnowledgeItem.updatedAt, order: .reverse) private var items: [KnowledgeItem]

    private var arguments: [String] { ProcessInfo.processInfo.arguments }

    var body: some View {
      if arguments.contains("--screenshot-privacy") {
        NavigationStack {
          PrivacyDataView()
        }
      } else if arguments.contains("--screenshot-detail") {
        NavigationStack {
          if let item = items.first(where: { $0.title == "Release Checklist" }) {
            KnowledgeDetailView(item: item)
          } else {
            ProgressView("Loading demo item…")
          }
        }
      } else {
        ContentView()
      }
    }
  }

  /// Fictional, deterministic content used only to produce privacy-safe App Store screenshots.
  /// Launch a clean simulator with `--screenshot-demo` to insert it once.
  @MainActor
  private enum ScreenshotDemoData {
    static func seedIfNeeded(context: ModelContext) {
      let descriptor = FetchDescriptor<KnowledgeItem>()
      guard (try? context.fetchCount(descriptor)) == 0 else { return }

      UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
      AutomationSettings.shared.autoTranscribe = false
      AutomationSettings.shared.autoAnalyze = false

      let now = Date()
      let day: TimeInterval = 86_400

      let launch = Project(
        name: "Mobile Launch",
        summary: "Release planning, positioning, and customer readiness",
        colorHex: "#2563EB",
        iconName: "paperplane.fill",
        createdAt: now.addingTimeInterval(-18 * day),
        updatedAt: now.addingTimeInterval(-1_800)
      )
      launch.nameIsAutoGenerated = false

      let research = Project(
        name: "Customer Research",
        summary: "Interview evidence and recurring product themes",
        colorHex: "#7C3AED",
        iconName: "person.2.fill",
        createdAt: now.addingTimeInterval(-30 * day),
        updatedAt: now.addingTimeInterval(-day)
      )
      research.nameIsAutoGenerated = false

      let studio = Project(
        name: "Brand Studio",
        summary: "Creative briefs, visual references, and launch assets",
        colorHex: "#DB2777",
        iconName: "paintpalette.fill",
        createdAt: now.addingTimeInterval(-12 * day),
        updatedAt: now.addingTimeInterval(-4 * day)
      )
      studio.nameIsAutoGenerated = false

      context.insert(launch)
      context.insert(research)
      context.insert(studio)

      let items: [(KnowledgeItem, Project?)] = [
        (
          item(
            type: .audio,
            title: "Launch Planning Session",
            body:
              "The team aligned on the release sequence, final quality checks, and customer communication plan.",
            status: .pendingReview,
            updatedAt: now.addingTimeInterval(-900),
            duration: 2_742,
            tags: ["launch", "planning"]
          ),
          launch
        ),
        (
          item(
            type: .note,
            title: "Release Checklist",
            body:
              "## Before release\n\n- Validate capture on a physical iPhone\n- Review privacy disclosures\n- Prepare support documentation\n- Confirm the final archive",
            status: .pendingReview,
            updatedAt: now.addingTimeInterval(-3_600),
            tags: ["release", "quality"]
          ),
          launch
        ),
        (
          item(
            type: .note,
            title: "Customer Interview — Creative Team",
            body:
              "The team wants one place to keep meeting context, reference documents, and decisions without losing the original source.",
            status: .pendingReview,
            updatedAt: now.addingTimeInterval(-day),
            tags: ["interview", "research"]
          ),
          research
        ),
        (
          item(
            type: .webBookmark,
            title: "Research Reading List",
            body: "A short collection of references for the next round of customer interviews.",
            status: .pendingReview,
            updatedAt: now.addingTimeInterval(-2 * day),
            tags: ["research"]
          ),
          research
        ),
        (
          item(
            type: .image,
            title: "Brand Direction Scan",
            body: "Scanned workshop page with the selected visual themes and tone words.",
            status: .pendingReview,
            updatedAt: now.addingTimeInterval(-4 * day),
            tags: ["brand", "scan"]
          ),
          studio
        ),
        (
          item(
            type: .journalEntry,
            title: "Weekly Reflection",
            body:
              "The strongest progress came from reducing scope and making every release promise verifiable.",
            status: .pendingReview,
            updatedAt: now.addingTimeInterval(-5 * day),
            tags: ["reflection"]
          ),
          nil
        ),
      ]

      for (knowledgeItem, project) in items {
        knowledgeItem.projectID = project?.id
        context.insert(knowledgeItem)
      }

      do {
        try context.save()
      } catch {
        assertionFailure("Unable to seed screenshot demo data: \(error)")
      }
    }

    private static func item(
      type: KnowledgeItemType,
      title: String,
      body: String,
      status: ItemStatus,
      updatedAt: Date,
      duration: Double? = nil,
      tags: [String]
    ) -> KnowledgeItem {
      let result = KnowledgeItem(
        type: type,
        title: title,
        createdAt: updatedAt.addingTimeInterval(-1_800),
        updatedAt: updatedAt,
        status: status,
        tags: tags,
        bodyText: body,
        durationSeconds: duration,
        languageCode: "en-US",
        inboxDate: updatedAt
      )
      if type == .audio {
        result.transcriptionEngineId = "apple-speech-on-device"
      }
      return result
    }
  }
#endif

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
