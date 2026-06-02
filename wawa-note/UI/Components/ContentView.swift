import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var showChat = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == 3 { showChat = true }
                else { selectedTab = newValue }
            }
        )) {
            NavigationStack { HomeView() }
                .tabItem { Label("Capture", systemImage: "mic.badge.plus") }.tag(0)

            NavigationStack { InboxView() }
                .tabItem { Label("Inbox", systemImage: "tray") }.tag(1)

            NavigationStack { ExploreView() }
                .tabItem { Label("Explore", systemImage: "rectangle.grid.1x2") }.tag(2)

            Color.clear
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(3)
        }
        .overlay(alignment: .bottom) { if showChat { chatOverlay } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    @ViewBuilder
    private var chatOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            ChatView(autoFocus: true, compact: true)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxHeight: UIScreen.main.bounds.height * 0.5)
        }
        .transition(.move(edge: .bottom))
    }
}

struct ExploreView: View {
    @State private var selectedTab: ExploreTab = .projects
    enum ExploreTab: String, CaseIterable {
        case projects = "Projects"; case timeline = "Timeline"
        var icon: String { switch self { case .projects: "folder"; case .timeline: "calendar.day.timeline.leading" } }
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                ForEach(ExploreTab.allCases, id: \.self) { tab in Label(tab.rawValue, systemImage: tab.icon).tag(tab) }
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            switch selectedTab {
            case .projects: ProjectListView()
            case .timeline: TimelineExplorerView()
            }
        }
    }
}
