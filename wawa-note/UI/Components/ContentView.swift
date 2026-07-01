import Combine
import SwiftData
import SwiftUI
import WawaNoteCore

extension Notification.Name {
  static let switchToInboxTab = Notification.Name("SwitchToInboxTab")
  static let switchToExploreTab = Notification.Name("SwitchToExploreTab")
  static let openSettings = Notification.Name("OpenSettings")
}

@MainActor
final class ChatOverlayState: ObservableObject {
  @Published var isActive = false
  @Published var context: ChatContext = .global
}

struct ContentView: View {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var processingQueue: ProcessingQueueService
  @State private var showSettings = false
  @State private var showChat = false
  @State private var showQueue = false
  @State private var selectedTab = 0
  @State private var keyboardHeight: CGFloat = 0
  @State private var safeAreaBottom: CGFloat = 0
  @StateObject private var chatState = ChatOverlayState()
  @StateObject private var chatViewModel = ChatViewModel()
  @Query(filter: #Predicate<KnowledgeItem> { $0.inboxDate != nil }) private var inboxItems:
    [KnowledgeItem]

  private var inboxPendingCount: Int { inboxItems.count }

  var body: some View {
    ZStack(alignment: .bottom) {
      TabView(
        selection: Binding(
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
        )
      ) {
        NavigationStack {
          HomeView()
            .toolbar {
              ToolbarItem(placement: .topBarTrailing) {
                Button {
                  showQueue = true
                } label: {
                  ZStack(alignment: .topTrailing) {
                    Image(systemName: "list.bullet.rectangle").accessibilityLabel("Queue")
                    let count = processingQueue.entries.filter {
                      $0.status == .queued || $0.status == .processing
                    }.count
                    if count > 0 {
                      Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.red))
                        .offset(x: 6, y: -6)
                    }
                  }
                }
              }
              ToolbarItem(placement: .topBarTrailing) {
                Button {
                  showSettings = true
                } label: {
                  Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
              }
            }
        }
        .tabItem { Label("Capture", systemImage: "mic.badge.plus") }
        .tag(0)

        NavigationStack { InboxView() }
          .tabItem { Label("Inbox", systemImage: "tray") }
          .badge(inboxPendingCount)
          .tag(1)

        NavigationStack { ExploreView() }
          .tabItem { Label("Explore", systemImage: "rectangle.grid.1x2") }
          .tag(2)

        Color.clear
          .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
          .tag(3)
      }
      .animation(.easeInOut(duration: 0.25), value: selectedTab)
      .ignoresSafeArea(.keyboard, edges: .bottom)

      if showChat {
        Color.black.opacity(0.3)
          .ignoresSafeArea()
          .onTapGesture {
            showChat = false
            chatState.isActive = false
          }
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

        ChatView(
          viewModel: chatViewModel, compact: true, autoFocus: true,
          onDismiss: {
            showChat = false
            chatState.isActive = false
          }
        )
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 8)
        .frame(maxHeight: UIScreen.main.bounds.height * 0.6, alignment: .bottom)
        .padding(.bottom, max(0, keyboardHeight - safeAreaBottom))
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .ignoresSafeArea(.keyboard, edges: .bottom)
    .environmentObject(chatState)
    .environmentObject(chatViewModel)
    .sheet(isPresented: $showSettings) { SettingsView() }
    .sheet(isPresented: $showQueue) { ProcessingQueueSheet() }
    .onReceive(keyboardPublisher) { keyboardHeight = $0 }
    .onReceive(NotificationCenter.default.publisher(for: .pipelineCompleted)) { _ in
      WawaNoteApp.updateAppBadge(modelContext: modelContext)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
    { _ in
      WawaNoteApp.updateAppBadge(modelContext: modelContext)
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchToInboxTab)) { _ in
      selectedTab = 1
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchToExploreTab)) { _ in
      selectedTab = 2
    }
    .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
      showSettings = true
    }
    .onAppear {
      chatViewModel.setup(modelContext: modelContext)
      chatViewModel.observeContext(from: chatState)
      _ = ConfigProjectService.ensureConfigProject(context: modelContext)
      ConfigProjectService.syncConfigProject(context: modelContext)
      WawaNoteApp.updateAppBadge(modelContext: modelContext)
      checkFirstLaunchConfig()
      autoProcessPendingItems()
      // Capture safe area bottom for keyboard positioning
      if let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first?.windows.first
      {
        safeAreaBottom = window.safeAreaInsets.bottom
      }
    }
  }

  /// Check minimum configuration state on launch and log guidance.
  private func checkFirstLaunchConfig() {
    let allConfigs = (try? modelContext.fetch(FetchDescriptor<AIProviderConfigModel>())) ?? []
    if allConfigs.isEmpty {
      AppLog.event(
        "lifecycle", "No AI providers configured — user should add a provider in Settings")
    } else {
      let withKeys = allConfigs.filter { $0.isAPIKeyPresent() }
      let activeID = ActiveProviderManager.shared.getActiveProviderID()
      if activeID == nil {
        AppLog.config.warning("Providers exist but none is active — auto-selecting first available")
      }
      AppLog.event(
        "lifecycle",
        "Config check: \(allConfigs.count) provider(s), \(withKeys.count) with API keys, active: \(activeID ?? "none")"
      )
    }
  }

  /// Scan for unprocessed items and enqueue them for background processing.
  private func autoProcessPendingItems() {
    let allItems = (try? modelContext.fetch(FetchDescriptor<KnowledgeItem>())) ?? []

    // ── Audio transcription (independent of autoAnalyze) ──────────
    // Share-imported audio should transcribe even when autoAnalyze is off.
    if AutomationSettings.shared.autoTranscribe {
      let needsTranscription = allItems.filter {
        $0.inboxDate != nil
          && $0.type == .audio
          && $0.transcriptionEngineId == nil
          && $0.status != .failed
      }
      if !needsTranscription.isEmpty {
        AppLog.event(
          "pipeline",
          "Auto-transcribing \(needsTranscription.count) pending audio item(s)")
        for item in needsTranscription.prefix(5) {
          processingQueue.enqueue(
            itemID: item.id, projectID: item.projectID, trigger: .backgroundBackfill)
        }
      }
    }

    // ── Analysis (requires autoAnalyze + provider) ────────────────
    guard AutomationSettings.shared.autoAnalyze else {
      AppLog.debug("lifecycle", "autoProcessPendingItems: autoAnalyze disabled — skipping analysis")
      return
    }
    guard (try? ProviderRouter.resolveActive(context: modelContext)) != nil else {
      AppLog.debug(
        "lifecycle", "autoProcessPendingItems: no provider configured — skipping analysis")
      return
    }

    let needsAnalysis = allItems.filter { $0.inboxDate != nil && $0.analysisProviderId == nil }
    guard !needsAnalysis.isEmpty else { return }

    AppLog.event(
      "pipeline", "Auto-processing \(needsAnalysis.count) pending item(s) for analysis")
    for item in needsAnalysis.prefix(5) {
      processingQueue.enqueue(
        itemID: item.id, projectID: item.projectID, trigger: .backgroundBackfill)
    }
  }

  private var keyboardPublisher: AnyPublisher<CGFloat, Never> {
    let show = NotificationCenter.default.publisher(
      for: UIResponder.keyboardWillChangeFrameNotification
    )
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
  @EnvironmentObject private var chatViewModel: ChatViewModel
  @State private var selectedTab: ExploreTab = .projects

  enum ExploreTab: String, CaseIterable {
    case projects = "Projects"
    case files = "Files"
    case timeline = "Timeline"

    var icon: String {
      switch self {
      case .projects: "folder"
      case .files: "filemenu.and.selection"
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
      case .files:
        FileBrowserView()
      case .timeline:
        TimelineExplorerView()
      }
    }
    .onAppear {
      chatState.context = .exploreProjects
      chatViewModel.pregenerateGreeting(for: .exploreProjects)
    }
  }
}

// MARK: - Processing Queue Sheet

struct ProcessingQueueSheet: View {
  @EnvironmentObject private var processingQueue: ProcessingQueueService
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        let active = processingQueue.entries.filter {
          $0.status == .queued || $0.status == .processing
        }
        if active.isEmpty {
          Section {
            VStack(spacing: 12) {
              Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
              Text("No items in queue").font(.headline)
              Text("Items will appear here when they are queued for processing.").font(.caption)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
          }
        } else {
          Section {
            ForEach(processingQueue.entries.prefix(20)) { entry in
              QueueEntryRow(entry: entry)
            }
            .onDelete { idx in
              for i in idx {
                if i < processingQueue.entries.count {
                  processingQueue.remove(processingQueue.entries[i].id)
                }
              }
            }
          } header: {
            HStack {
              if processingQueue.isPaused {
                Label("Paused", systemImage: "pause.fill").foregroundStyle(.orange)
              } else if !active.isEmpty {
                Label("Active", systemImage: "gearshape.2.fill").foregroundStyle(.blue)
              }
              Spacer()
              Text("\(active.count) queued, \(processingQueue.activeJobCount) running").font(
                .caption
              ).foregroundStyle(.secondary)
            }
          }
        }
        // Clear completed/failed — inside the List
        if !processingQueue.entries.isEmpty {
          let hasDone = processingQueue.entries.contains { $0.status == .done }
          let hasFailed = processingQueue.entries.contains { $0.status == .failed }
          if hasDone || hasFailed {
            Section {
              if hasDone {
                Button("Clear Completed") { processingQueue.clearCompleted() }
                  .foregroundStyle(.secondary)
              }
              if hasFailed {
                Button("Clear Failed", role: .destructive) {
                  processingQueue.clearFailed()
                }
              }
            }
          }
        }
      }
      .navigationTitle("Processing Queue")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          HStack(spacing: 16) {
            Button(processingQueue.isPaused ? "Resume" : "Pause") {
              if processingQueue.isPaused {
                processingQueue.resumeQueue()
              } else {
                processingQueue.pauseQueue()
              }
            }
            let activeCount = processingQueue.entries.filter {
              $0.status == .queued || $0.status == .processing
            }.count
            if activeCount > 0 {
              Button("Cancel All", role: .destructive) {
                processingQueue.cancelAll()
              }
            }
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

private struct QueueEntryRow: View {
  let entry: QueueEntry
  @EnvironmentObject private var processingQueue: ProcessingQueueService

  var body: some View {
    HStack(spacing: 12) {
      Image(
        systemName: entry.status == .processing
          ? "gearshape.2.fill"
          : entry.status == .done
            ? "checkmark.circle.fill" : entry.status == .failed ? "xmark.circle.fill" : "circle"
      )
      .foregroundStyle(
        entry.status == .processing
          ? .blue
          : entry.status == .done
            ? .green : entry.status == .failed ? .red : entry.status == .cancelled ? .gray : .orange
      )
      VStack(alignment: .leading, spacing: 2) {
        Text("Item \(entry.itemID.uuidString.prefix(8))...").font(.caption).lineLimit(1)
        Text(statusText).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      // Explicit cancel button for queued/processing items
      if entry.status == .queued || entry.status == .processing {
        Button {
          processingQueue.cancel(entry.id)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .font(.title3)
        }
        .buttonStyle(.plain)
      }
      PriorityBadge(score: entry.priority)
    }
    .padding(.vertical, 2)
  }

  private var statusText: String {
    switch entry.status {
    case .queued: return "Waiting (priority: \(entry.priority))"
    case .processing: return "Processing..."
    case .paused: return "Paused"
    case .done: return "Completed"
    case .failed: return entry.lastError.map { "Failed: \($0.prefix(40))" } ?? "Failed"
    case .cancelled: return "Cancelled"
    case .waitingForUser: return "Waiting for you"
    }
  }
}

private struct PriorityBadge: View {
  let score: Int
  var body: some View {
    let color: Color = score >= 70 ? .red : score >= 50 ? .orange : .blue
    Text("P\(score)").font(.caption2).fontWeight(.medium)
      .padding(.horizontal, 6).padding(.vertical, 1)
      .background(color.opacity(0.15)).clipShape(Capsule())
      .foregroundStyle(color)
  }
}
