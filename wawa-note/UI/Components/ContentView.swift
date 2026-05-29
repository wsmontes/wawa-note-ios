import SwiftUI

struct ContentView: View {
    @State private var showSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
            }
            .tabItem {
                Label("Capture", systemImage: "mic.badge.plus")
            }

            InboxView()
                .tabItem {
                    Label("Inbox", systemImage: "tray")
                }

            NavigationStack {
                ExploreView()
            }
            .tabItem {
                Label("Explore", systemImage: "rectangle.grid.1x2")
            }

            NavigationStack {
                ChatView()
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

struct ExploreView: View {
    @State private var selectedTab: ExploreTab = .library

    enum ExploreTab: String, CaseIterable {
        case library = "Library"
        case projects = "Projects"
        case timeline = "Timeline"

        var icon: String {
            switch self {
            case .library: "list.bullet.rectangle"
            case .projects: "folder"
            case .timeline: "calendar.day.timeline.leading"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                ForEach(ExploreTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case .library:
                KnowledgeListView()
            case .projects:
                ProjectListView()
            case .timeline:
                TimelineExplorerView()
            }
        }
    }
}
