import SwiftUI
import SwiftData

@main
struct WawaNoteApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: MeetingModel.self, AIProviderConfigModel.self,
                ChatConversationModel.self, ChatMessageModel.self
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
