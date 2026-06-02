import SwiftUI
import Combine

final class ChatState: ObservableObject {
    @Published var isActive = false
}

struct ContentView: View {
    @State private var showSettings = false
    @State private var showChat = false
    @State private var selectedTab = 0
    @State private var keyboardHeight: CGFloat = 0
    @StateObject private var chatState = ChatState()

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: Binding(
                get: { selectedTab },
                set: { newValue in
                    if newValue == 3 {
                        showChat = true
                        chatState.isActive = true
                    } else {
                        showChat = false
                        chatState.isActive = false
                        selectedTab = newValue
                    }
                }
            )) {
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
                .tag(0)

                NavigationStack { InboxView() }
                    .tabItem { Label("Inbox", systemImage: "tray") }
                    .tag(1)

                NavigationStack { ExploreView() }
                    .tabItem { Label("Explore", systemImage: "rectangle.grid.1x2") }
                    .tag(2)

                Color.clear
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(3)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .environmentObject(chatState)

            Color.black.opacity(showChat ? 0.3 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(showChat)
                .onTapGesture { showChat = false; chatState.isActive = false }
                .animation(.easeInOut(duration: 0.25), value: showChat)

            ChatView(compact: true, autoFocus: showChat, onDismiss: {
                showChat = false
                chatState.isActive = false
            })
                .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 8)
                .frame(maxHeight: UIScreen.main.bounds.height * 0.6, alignment: .bottom)
                .padding(.bottom, showChat ? max(0, keyboardHeight - 6) : 0)
                .opacity(showChat ? 1 : 0)
                .allowsHitTesting(showChat)
                .animation(.easeInOut(duration: 0.25), value: showChat)
                .animation(.easeInOut(duration: 0.25), value: keyboardHeight)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onReceive(keyboardPublisher) { keyboardHeight = $0 }
    }

    private var keyboardPublisher: AnyPublisher<CGFloat, Never> {
        let show = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .map { n in
                let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
                return max(0, UIScreen.main.bounds.height - frame.minY)
            }
        let hide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }
        return Publishers.Merge(show, hide).eraseToAnyPublisher()
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
