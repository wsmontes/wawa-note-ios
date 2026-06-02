import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @State private var showChat = false
    @State private var chatDetent: ChatDetent = .prompt
    @State private var chatContext: String = "global"

    enum ChatDetent { case prompt, half, full }

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Capture", systemImage: "mic.badge.plus") }

            NavigationStack {
                InboxView()
            }
            .tabItem { Label("Inbox", systemImage: "tray") }

            NavigationStack {
                ExploreView()
            }
            .tabItem { Label("Explore", systemImage: "rectangle.grid.1x2") }
        }
        .overlay(alignment: .bottom) { chatOverlay }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button { withAnimation(.spring) { showChat = true; chatDetent = .prompt } } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .accessibilityLabel("Chat")
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").accessibilityLabel("Settings")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: Chat Overlay

    @ViewBuilder
    private var chatOverlay: some View {
        if showChat {
            ZStack(alignment: .bottom) {
                Color.black.opacity(chatDetent == .full ? 0 : 0.3).ignoresSafeArea()
                    .onTapGesture { dismissChat() }

                VStack(spacing: 0) {
                    // Drag handle
                    Capsule().fill(Color(.tertiaryLabel)).frame(width: 36, height: 5).padding(.top, 8)

                    // Chat content
                    ChatView()

                    // Prompt bar (always visible at bottom of overlay)
                    if chatDetent != .full {
                        Divider()
                        promptBar
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: chatDetent == .prompt ? 88 :
                               chatDetent == .half ? UIScreen.main.bounds.height * 0.5 :
                               UIScreen.main.bounds.height
                )
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            let v = value.translation.height
                            if v > 80 { showChat = false } // swipe down = dismiss
                            else if v < -80 && chatDetent == .prompt { chatDetent = .half } // swipe up = expand
                            else if v < -80 && chatDetent == .half { chatDetent = .full }
                        }
                )
            }
            .transition(.move(edge: .bottom))
        }
    }

    private var promptBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about anything...", text: .constant(""))
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            Button {
                withAnimation(.spring) { chatDetent = .half }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func dismissChat() {
        withAnimation(.spring) { showChat = false }
    }
}

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
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)

            switch selectedTab {
            case .projects: ProjectListView()
            case .timeline: TimelineExplorerView()
            }
        }
    }
}
