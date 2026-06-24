import SwiftUI
import SwiftData
import EventKit
import LocalAuthentication
import UserNotifications
// Related JIRA: KAN-11, KAN-55, KAN-57, KAN-58


@main
struct WawaNoteApp: App {
    private let modelContainer: ModelContainer
    private let recordingCoordinator: RecordingCoordinator
    private let calendarSyncService: CalendarSyncService
    private let sharedEventStore: EKEventStore

    private let ingestionState: ProjectIngestionState
    private let contentPipeline: ContentPipelineService
    private let processingQueue: ProcessingQueueService
    private let serviceContainer: ServiceContainer

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
            Person.self,
            GraphEdge.self,
            Entity.self,
            TaskItem.self,
            AgentSuggestion.self,
            QueueEntry.self,
            ProjectFrame.self,
            ChangeRecord.self,
            ProjectSnapshot.self,
            ProjectDerivedItem.self,
            ProjectSuggestion.self
        ])
        if isTesting {
            // In-memory store for tests — no disk I/O, fast setup
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            modelContainer = try! ModelContainer(for: schema, configurations: config)
        } else {
            modelContainer = Self.createModelContainer(schema: schema)
        }

        ingestionState = ProjectIngestionState()
        contentPipeline = ContentPipelineService(ingestionState: ingestionState, modelContainer: modelContainer)
        processingQueue = ProcessingQueueService()
        processingQueue.setPipeline(contentPipeline)

        serviceContainer = ServiceContainer(context: ModelContext(modelContainer))

        let coordinator = RecordingCoordinator(modelContainer: modelContainer)
        coordinator.contentPipeline = contentPipeline
        coordinator.processingQueue = processingQueue
        recordingCoordinator = coordinator

        sharedEventStore = EKEventStore()
        calendarSyncService = CalendarSyncService(eventStore: sharedEventStore)

        // Anarlog: import/export only (KAN-258)

        // Run one-time data migrations via centralized registry
        let migrationContext = ModelContext(modelContainer)
        MigrationRegistry.runPendingMigrations(context: migrationContext)

        // Setup notifications
        setupNotifications()

        // Initialize persistent file logging (survives crashes)
        let fileLog = FileLogService.shared

        // Clean up any recordings abandoned by a previous crash or force-quit
        coordinator.cleanupOrphanedRecordings()

        // Request location permission early so it's ready when recording starts
        LocationContextSensor().requestPermission()

        if fileLog.previousSessionCrashed {
            AppLog.warn("general", "⚠️ Previous session ended abnormally — crash log available in Settings > Debug Logs")
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
        let config = ModelConfiguration(schema: schema)
        return createModelContainer(schema: schema, config: config)
    }

    private static func createModelContainer(schema: Schema, config: ModelConfiguration) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            AppLog.warn("general", "⚠️ ModelContainer load failed — recreating store. Error: \(error)")

            // Back up existing store files before destruction
            StoreBackup.backup()

            // Delete stores in all possible locations (app container + App Group)
            Self.destroyAllStores()

            // Retry with fresh store
            let freshConfig = ModelConfiguration(schema: schema)
            do {
                return try ModelContainer(for: schema, configurations: freshConfig)
            } catch {
                fatalError("Could not create ModelContainer after store recreation: \(error)")
            }
        }
    }

    /// Deletes default.store files from both the app container and App Group container.
    private static func destroyAllStores() {
        var searchDirs: [URL] = []

        // App container Application Support
        if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            searchDirs.append(appSupport)
        }

        // App Group container
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") {
            searchDirs.append(groupURL.appendingPathComponent("Library/Application Support"))
        }

        for dir in searchDirs {
            Self.destroyStore(at: dir.appendingPathComponent("default.store"))
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
            storeFileName,                   // default.store
            storeFileName + "-shm",          // default.store-shm
            storeFileName + "-wal",          // default.store-wal
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
                /// Items needing review: in inbox, not trashed, not yet analyzed.
                /// Matches InboxView.needsReviewCount so badge reflects visible content.
                let inboxCount = allItems.filter { item in
                    item.inboxDate != nil
                    && item.analysisProviderId == nil
                    && (trashFolderID == nil || item.folderID != trashFolderID)
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
        .environmentObject(processingQueue)
        .environmentObject(serviceContainer)
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
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
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
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Wawa Note to access your knowledge workspace.")
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
