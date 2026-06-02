import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var showChat = false
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            TabView(selection: Binding(
                get: { selectedTab },
                set: { newValue in
                    if newValue == 3 {
                        showChat = true  // Chat tab opens overlay, not tab switch
                    } else {
                        selectedTab = newValue
                    }
                }
            )) {
                NavigationStack { HomeView() }
                    .tabItem { Label("Capture", systemImage: "mic.badge.plus") }.tag(0)

                NavigationStack { InboxView() }
                    .tabItem { Label("Inbox", systemImage: "tray") }.tag(1)

                NavigationStack { ExploreView() }
                    .tabItem { Label("Explore", systemImage: "rectangle.grid.1x2") }.tag(2)

                // Chat tab — intercepted to open overlay instead
                Color.clear
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(3)
            }

            // Chat overlay
            if showChat {
                chatOverlay
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: Chat Overlay

    @State private var chatFocusTrigger = false

    @ViewBuilder
    private var chatOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.2).ignoresSafeArea()
                .onTapGesture { dismissChat() }

            VStack(spacing: 0) {
                ChatView(autoFocus: true)
            }
            .frame(maxWidth: .infinity, maxHeight: UIScreen.main.bounds.height * 0.5)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .transition(.move(edge: .bottom))
            .onAppear { chatFocusTrigger.toggle() }
        }
    }

    private func dismissChat() {
        withAnimation(.spring) { showChat = false }
    }
}

struct ExploreView: View {
    @State private var selectedTab: ExploreTab = .projects

    enum ExploreTab: String, CaseIterable {
        case projects = "Projects"
        case timeline = "Timeline"
        var icon: String {
            switch self {
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
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)

            switch selectedTab {
            case .projects: ProjectListView()
            case .timeline: TimelineExplorerView()
            }
        }
    }
}
