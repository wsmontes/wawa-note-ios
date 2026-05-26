import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            MeetingsListView()
                .tabItem {
                    Label("Meetings", systemImage: "list.bullet.rectangle")
                }

            ChatListView()
                .tabItem {
                    Label("Chat", systemImage: "message")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    ContentView()
}
