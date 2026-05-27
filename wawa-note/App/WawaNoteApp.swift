import SwiftUI
import SwiftData

@main
struct WawaNoteApp: App {
    private let modelContainer: ModelContainer
    private let recordingCoordinator: RecordingCoordinator
    private let watchSessionManager: iOSWatchSessionManager
    private let calendarSyncService: CalendarSyncService

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
                Entity.self
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        let coordinator = RecordingCoordinator(modelContainer: modelContainer)
        recordingCoordinator = coordinator

        watchSessionManager = iOSWatchSessionManager(coordinator: coordinator)
        watchSessionManager.activate()

        calendarSyncService = CalendarSyncService()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
        .environmentObject(recordingCoordinator)
        .environmentObject(calendarSyncService)
    }
}
