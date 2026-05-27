import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            NavigationStack {
                KnowledgeListView()
            }
            .tabItem {
                Label("Knowledge", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                ProjectListView()
            }
            .tabItem {
                Label("Projects", systemImage: "folder")
            }

            KnowledgeQueryView()
                .tabItem {
                    Label("Ask", systemImage: "sparkle.magnifyingglass")
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
