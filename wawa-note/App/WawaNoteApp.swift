import SwiftUI
import SwiftData
import EventKit
import LocalAuthentication
import UserNotifications

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
        do {
            modelContainer = try ModelContainer(
                for: AIProviderConfigModel.self,
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
                ProjectSnapshot.self
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        ingestionState = ProjectIngestionState()
        ingestionPipeline = ProjectIngestionPipeline(ingestionState: ingestionState)
        contentPipeline = ContentPipelineService(ingestionPipeline: ingestionPipeline, ingestionState: ingestionState, modelContainer: modelContainer)
        processingQueue = ProcessingQueueService()
        processingQueue.setPipeline(contentPipeline)

        let coordinator = RecordingCoordinator(modelContainer: modelContainer)
        coordinator.contentPipeline = contentPipeline
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
