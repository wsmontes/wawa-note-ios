import SwiftUI
import SwiftData
import EventKit
import LocalAuthentication

@main
struct WawaNoteApp: App {
    private let modelContainer: ModelContainer
    private let recordingCoordinator: RecordingCoordinator
    private let watchSessionManager: iOSWatchSessionManager
    private let calendarSyncService: CalendarSyncService
    private let sharedEventStore: EKEventStore

    private let ingestionState: ProjectIngestionState
    private let contentPipeline: ContentPipelineService
    private let ingestionPipeline: ProjectIngestionPipeline

    @StateObject private var biometricGate = BiometricGateService()

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
                AgentSuggestion.self
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        ingestionState = ProjectIngestionState()
        ingestionPipeline = ProjectIngestionPipeline(ingestionState: ingestionState)
        contentPipeline = ContentPipelineService(ingestionPipeline: ingestionPipeline, ingestionState: ingestionState)

        let coordinator = RecordingCoordinator(modelContainer: modelContainer)
        coordinator.contentPipeline = contentPipeline
        recordingCoordinator = coordinator

        watchSessionManager = iOSWatchSessionManager(coordinator: coordinator)
        watchSessionManager.activate()

        sharedEventStore = EKEventStore()
        calendarSyncService = CalendarSyncService(eventStore: sharedEventStore)

        // Run one-time data migrations
        KnowledgeItemService.migrateMeetingToAudio(context: ModelContext(modelContainer))
        ProjectService.migrateProjectColors(context: ModelContext(modelContainer))
    }

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
    }
}

// MARK: - Biometric Gate

@MainActor
final class BiometricGateService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "face_id_enabled") }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "face_id_enabled")
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
