import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var showChatOverlay = false
    @State private var chatOffset: CGFloat = UIScreen.main.bounds.height

    var body: some View {
        ZStack {
            TabView {
                NavigationStack {
                    HomeView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { showSettings = true } label: {
                                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                                }
                            }
                        }
                }
                .tabItem { Label("Capture", systemImage: "mic.badge.plus") }

                InboxView()
                    .tabItem { Label("Inbox", systemImage: "tray") }

                NavigationStack {
                    ExploreView()
                }
                .tabItem { Label("Explore", systemImage: "rectangle.grid.1x2") }

                NavigationStack {
                    ChatView()
                }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            }

            // Floating chat button (visible on all tabs)
            VStack { Spacer()
                HStack { Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.35)) { chatOffset = 60 }
                        showChatOverlay = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.blue, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }
                    .padding(.trailing, 20).padding(.bottom, 90)
                }
            }

            // Chat overlay
            if showChatOverlay {
                Color.black.opacity(0.3).ignoresSafeArea()
                    .onTapGesture { dismissChat() }
                    .transition(.opacity)

                VStack(spacing: 0) {
                    // Drag handle
                    Capsule().fill(Color(.tertiaryLabel)).frame(width: 36, height: 5).padding(.top, 8)
                    ChatOverlayView(onDismiss: dismissChat)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .offset(y: chatOffset)
                .transition(.move(edge: .bottom))
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func dismissChat() {
        withAnimation(.spring(duration: 0.35)) { chatOffset = UIScreen.main.bounds.height }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showChatOverlay = false }
    }
}

// MARK: - Chat Overlay

struct ChatOverlayView: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ChatView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onDismiss() } label: {
                            Image(systemName: "chevron.down").fontWeight(.semibold)
                        }
                    }
                }
        }
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
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case .projects:
                ProjectListView()
            case .timeline:
                TimelineExplorerView()
            }
        }
    }
}
