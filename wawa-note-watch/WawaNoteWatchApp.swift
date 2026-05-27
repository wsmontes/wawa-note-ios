import SwiftUI

@main
struct WawaNoteWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager()

    var body: some Scene {
        WindowGroup {
            WatchRecordingView()
                .environmentObject(sessionManager)
                .onAppear { sessionManager.activate() }
        }
    }
}
