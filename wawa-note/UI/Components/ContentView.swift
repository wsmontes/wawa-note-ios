import SwiftUI
import Combine

final class ChatOverlayState: ObservableObject {
    @Published var isActive = false
    @Published var context: ChatContext = .global
}

struct ContentView: View {
    @State private var showSettings = false
    @State private var showChat = false
    @State private var selectedTab = 0
    @State private var keyboardHeight: CGFloat = 0
    @StateObject private var chatState = ChatOverlayState()
    @StateObject private var chatViewModel = ChatViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: Binding(
                get: { selectedTab },
                set: { newValue in
                    if newValue == 3 {
                        showChat = true
                        chatState.isActive = true
                        chatViewModel.syncContextIfNeeded()
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

            if showChat {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showChat = false; chatState.isActive = false }
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.height > 50, abs(value.translation.width) < 30 {
                                    showChat = false
                                    chatState.isActive = false
                                }
                            }
                    )
                    .transition(.opacity)

                ChatView(viewModel: chatViewModel, compact: true, autoFocus: true, onDismiss: {
                    showChat = false
                    chatState.isActive = false
                })
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 8)
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.6, alignment: .bottom)
                    .padding(.bottom, max(0, keyboardHeight - 6))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .environmentObject(chatState)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onReceive(keyboardPublisher) { keyboardHeight = $0 }
        .onAppear {
            chatViewModel.observeContext(from: chatState)
        }
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
    @EnvironmentObject private var chatState: ChatOverlayState
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
        .onAppear { chatState.context = .exploreProjects }
    }
}
