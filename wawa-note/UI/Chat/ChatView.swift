import SwiftUI
import SwiftData
import Speech
import AVFoundation

struct TableBlockView: View {
    let table: TableBlock
    @State private var sortColumn: Int? = nil
    @State private var sortAscending = true

    private var sortedRows: [[String]] {
        guard let col = sortColumn, col < table.headers.count else { return table.rows }
        return table.rows.sorted {
            let a = col < $0.count ? $0[col] : ""
            let b = col < $1.count ? $1[col] : ""
            return sortAscending ? a < b : a > b
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = table.title {
                Text(title).font(.headline)
            }
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        ForEach(Array(table.headers.enumerated()), id: \.offset) { idx, header in
                            Button {
                                if sortColumn == idx { sortAscending.toggle() }
                                else { sortColumn = idx; sortAscending = true }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(header).font(.caption).fontWeight(.bold)
                                    if sortColumn == idx {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color(.secondarySystemBackground))
                            }
                            .buttonStyle(.plain)
                            if idx < table.headers.count - 1 {
                                Divider().frame(width: 1)
                            }
                        }
                    }
                    Divider()
                    // Rows
                    ForEach(Array(sortedRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { idx, cell in
                                Text(cell).font(.caption).foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                if idx < row.count - 1 {
                                    Divider().frame(width: 1)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
            HStack { Spacer(); Text("\(table.rows.count) rows").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 4)
    }
}
struct ActionBlockView: View {
    let actions: ActionBlock
    @State private var checked: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = actions.title {
                Text(title).font(.headline)
            }
            ForEach(Array(actions.items.enumerated()), id: \.offset) { idx, item in
                HStack(spacing: 8) {
                    Button { checked.insert(idx) } label: {
                        Image(systemName: checked.contains(idx) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(checked.contains(idx) ? .green : .secondary)
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.task).font(.subheadline).strikethrough(checked.contains(idx))
                        HStack(spacing: 8) {
                            if let owner = item.owner { Label(owner, systemImage: "person").font(.caption2).foregroundStyle(.secondary) }
                            if let due = item.dueDate { Label(due, systemImage: "calendar").font(.caption2).foregroundStyle(.secondary) }
                            if let pri = item.priority { Label(pri, systemImage: "flag").font(.caption2).foregroundStyle(pri == "high" ? .red : .secondary) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
}
struct CardBlockView: View {
    let card: CardBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.title).font(.headline)
                Spacer()
                if let badge = card.badge {
                    Text(badge).font(.caption2).fontWeight(.semibold).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1)).clipShape(Capsule())
                }
            }
            Text(card.body).font(.subheadline).foregroundStyle(.secondary)
            if !card.entities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(card.entities, id: \.self) { entity in
                            Text(entity).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(.secondarySystemBackground)).clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator)))
        .padding(.vertical, 4)
    }
}
struct BulletListView: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).font(.subheadline)
                }
            }
        }.padding(.vertical, 2)
    }
}
struct OrderedListView: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(idx + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text(item).font(.subheadline)
                }
            }
        }.padding(.vertical, 2)
    }
}
struct CodeBlockView: View {
    let codeBlock: CodeBlock
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let lang = codeBlock.language {
                    Text(lang).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = codeBlock.code
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
            }
            Text(codeBlock.code).font(.system(.footnote, design: .monospaced))
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let caption = codeBlock.caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
struct KnowledgeItemNavigationView: View {
    let itemID: UUID
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
            KnowledgeDetailView(item: item)
        } else {
            Text("Item not found").font(.headline).foregroundStyle(.secondary)
        }
    }
}
struct EvidenceCardView: View {
    let itemTitle: String; let itemID: UUID; let snippet: String
    let segmentID: String?; let confidence: Double?; let edgeType: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(itemTitle).font(.caption).fontWeight(.medium).lineLimit(1)
                Text(snippet.prefix(120)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let seg = segmentID { Text("Seg \(seg.prefix(8))").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    if let conf = confidence { ConfidenceBadge(value: conf) }
                    if let et = edgeType { Text(et).font(.system(size: 9)).padding(.horizontal,4).padding(.vertical,1).background(Color.blue.opacity(0.1)).clipShape(Capsule()) }
                }
            }
            Spacer()
        }
        .padding(8).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
struct ConfidenceBadge: View {
    let value: Double
    private var color: Color { value >= 0.8 ? .green : value >= 0.5 ? .orange : .gray }

    var body: some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(Int(value * 100))%").font(.system(size: 9)).foregroundStyle(color)
        }
    }
}
struct AIGeneratedBadge: View {
    let confidence: Double?; let source: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 8))
            Text(source ?? "AI").font(.system(size: 9))
            if let conf = confidence { ConfidenceBadge(value: conf) }
        }
        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.08)).clipShape(Capsule())
    }
}
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    var compact: Bool = false
    var autoFocus: Bool = false
    var onDismiss: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @State private var showConversations = false
    @State private var showClearConfirmation = false
    @FocusState private var isInputFocused: Bool
    @State private var isDictating = false
    @State private var dictationError: String?
    @State private var dictationTask: Task<Void, Never>?
    @State private var audioRecorder: AVAudioRecorder?
    @State private var audioEngine: AVAudioEngine?
    @State private var showSuggestions = false
    // Polished dictation UI states
    @State private var dictationElapsed: Double = 0
    @State private var dictationLevel: Float = 0
    @State private var dictationPhase: DictationPhase = .idle
    @State private var dictationTimer: Timer?

    enum DictationPhase {
        case idle, recording, transcribing, done
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                let showHeader = true  // Always show in compact mode
                if showHeader {
                    VStack(spacing: 0) {
                        HStack {
                            // Left: context + dismiss
                            HStack(spacing: 8) {
                                if let dismiss = onDismiss, !viewModel.messages.isEmpty {
                                    Button { dismiss() } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title3).foregroundStyle(.primary.opacity(0.7))
                                    }.buttonStyle(.plain)
                                }
                                if let proj = viewModel.activeProjectName {
                                    HStack(spacing: 4) {
                                        Circle().fill(viewModel.activeProjectColorHex.flatMap { Color(hex: $0) } ?? .blue).frame(width: 7, height: 7)
                                        Text(proj).font(.caption).fontWeight(.medium).lineLimit(1)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.ultraThinMaterial, in: Capsule())
                                }
                            }
                            Spacer()
                            // Right: status + actions
                            HStack(spacing: 8) {
                                if viewModel.isGreetingLoading {
                                    HStack(spacing: 4) { ProgressView().scaleEffect(0.7); Text("Prep...").font(.caption2).foregroundStyle(.secondary) }
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(.ultraThinMaterial, in: Capsule())
                                } else if viewModel.state == .thinking {
                                    HStack(spacing: 4) { ProgressView().scaleEffect(0.7); Text("Thinking").font(.caption2).foregroundStyle(.secondary) }
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(.ultraThinMaterial, in: Capsule())
                                } else if viewModel.state == .streaming {
                                    HStack(spacing: 4) { Circle().fill(.blue).frame(width: 5, height: 5); Text("Writing").font(.caption2).foregroundStyle(.secondary) }
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(.ultraThinMaterial, in: Capsule())
                                } else if !viewModel.activeToolCalls.isEmpty {
                                    HStack(spacing: 4) { ProgressView().scaleEffect(0.6); Text(viewModel.activeToolCalls.last?.toolName ?? "Tool").font(.caption2).foregroundStyle(.secondary) }
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(.ultraThinMaterial, in: Capsule())
                                }
                                Menu {
                                    Button { viewModel.createNewConversation() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                                    Button { showConversations = true } label: { Label("Chats", systemImage: "list.bullet.rectangle") }
                                    if !viewModel.messages.isEmpty {
                                        Divider()
                                        Button(role: .destructive) { showClearConfirmation = true } label: { Label("Clear Chat", systemImage: "trash") }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3).foregroundStyle(.primary.opacity(0.7))
                                }
                            }
                        }
                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                    }
                }
            }
            if !compact, let projectName = viewModel.activeProjectName {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full").font(.caption).foregroundStyle(.blue)
                    Text(projectName).font(.caption).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Button {
                        viewModel.sendInternalMessage("Tell me about the status of project '\(projectName)'")
                    } label: {
                        Text("Ask").font(.caption2).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.blue.opacity(0.1)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Button { viewModel.activeProjectID = nil; viewModel.activeProjectName = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.blue.opacity(0.04))
            }
            if !compact || !viewModel.messages.isEmpty || !viewModel.streamingText.isEmpty {
                messageList
                    .navigationDestination(for: UUID.self) { itemID in
                        KnowledgeItemNavigationView(itemID: itemID)
                    }
            }
            // Suggestion bar — revealed when user scrolls up past newest content (Fix 17)
            if showSuggestions, !viewModel.messages.isEmpty {
                suggestionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Dictation recording status bar — free recording, user stops when done
            if dictationPhase == .recording {
                HStack(spacing: 10) {
                    // Pulsing red dot
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1.0 + 0.3 * sin(dictationElapsed * 5))
                        .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: dictationElapsed)
                    // Audio level waveform
                    HStack(spacing: 2) {
                        ForEach(0..<10, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.red.opacity(0.5))
                                .frame(width: 2, height: CGFloat(4 + 14 * abs(sin(dictationElapsed * 4 + Double(i) * 0.7))))
                                .animation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true), value: dictationElapsed)
                        }
                    }
                    .frame(height: 18)
                    // Elapsed time counting UP
                    Text(formatElapsed(dictationElapsed))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    // Stop (finish and transcribe)
                    Button(action: finishDictation) {
                        Image(systemName: "stop.fill")
                            .font(.body).foregroundStyle(.red)
                            .frame(width: 36, height: 36)
                            .background(Color.red.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }

            // Transcribing indicator
            if dictationPhase == .transcribing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Transcribing...").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }

            // Dictation error (works in both compact and full mode)
            if let dictErr = dictationError {
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash").foregroundStyle(.red).font(.caption)
                    Text(dictErr).font(.caption).foregroundStyle(.red)
                    Spacer()
                    if dictErr.contains("Settings") {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }.font(.caption)
                    }
                    Button("Dismiss") { dictationError = nil }.font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.red.opacity(0.08))
            }

            if !compact || !viewModel.messages.isEmpty || !viewModel.streamingText.isEmpty { Divider() }
            chatInputBar
        }
        .navigationTitle(compact ? "" : (viewModel.currentConversation?.title.isEmpty != false ? "Chat" : viewModel.currentConversation?.title ?? "Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 16) {
                    Button {
                        showConversations = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .accessibilityLabel("Conversations")
                    }
                    if !viewModel.messages.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .accessibilityLabel("Clear chat")
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Picker("Mode", selection: $viewModel.mode) {
                        Image(systemName: "circle.grid.3x3").tag(AgentMode.auto)
                        Image(systemName: "brain.head.profile").tag(AgentMode.deep)
                        Image(systemName: "bolt").tag(AgentMode.fast)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    ActiveModelPicker(selectedModel: $viewModel.selectedModel, label: "Model")
                }
            }
        }
        .sheet(isPresented: $showConversations) {
            ConversationListView(viewModel: viewModel)
        }
        .alert("Clear chat?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) { viewModel.clearCurrentConversation() }
        } message: {
            Text("This deletes all messages in this conversation. This cannot be undone.")
        }
        .onAppear {
            viewModel.setup(modelContext: modelContext)
            viewModel.loadConversations()
            if autoFocus { isInputFocused = true }
        }
        .onChange(of: autoFocus) { _, focus in
            isInputFocused = focus
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Dismiss keyboard on tap in message area
                Color.clear.frame(height: 0)
                    .contentShape(Rectangle())
                    .onTapGesture { isInputFocused = false }

                if viewModel.messages.isEmpty && viewModel.streamingText.isEmpty && viewModel.error == nil {
                    // Empty state centered in available space (outside LazyVStack so Spacer works)
                    GeometryReader { geometry in
                        VStack {
                            Spacer()
                            emptyState
                            Spacer()
                        }
                        .frame(width: geometry.size.width)
                        .frame(minHeight: geometry.size.height)
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { msg in
                            // Skip internal messages — they're in agent history but invisible in UI
                            if msg.isInternal { EmptyView() }
                            else if msg.role == .assistant || msg.role == .tool {
                                ParsedMessageView(message: msg, projectColorHex: viewModel.activeProjectColorHex,
                                    onSendMessage: { text in viewModel.sendInternalMessage(text) },
                                    onRunCommand: { cmd in viewModel.runCommandDirectly(cmd) },
                                    onChooseOption: { option in viewModel.sendInternalMessage(option) })
                                    .id(msg.id)
                            } else {
                                ChatMessageBubbleView(message: msg, projectColorHex: viewModel.activeProjectColorHex)
                                    .id(msg.id)
                            }
                        }

                        // Pipeline progress (from ContentPipelineService)
                        if let status = contentPipeline.pipelineStatus {
                            PipelineProgressCardView(status: status)
                        }

                        // Unified agent status — replaces individual tool call cards
                        if viewModel.state == .thinking || !viewModel.activeToolCalls.isEmpty {
                            AgentStatusBar(
                                state: viewModel.state,
                                toolCalls: viewModel.activeToolCalls
                            )
                        }

                        // Streaming text
                        if !viewModel.streamingText.isEmpty {
                            StreamingMessageView(text: viewModel.streamingText, projectColorHex: viewModel.activeProjectColorHex)
                                .id("streaming")
                        }

                        if let error = viewModel.error {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.red)
                                    Spacer()
                                    Button("Retry") { viewModel.retryLastMessage() }
                                        .font(.subheadline.bold())
                                }
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal)
                        }

                        // Invisible anchor for auto-scroll
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 12)
                }
            }
            .background(compact ? Color.clear : Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { isInputFocused = false }
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                if newCount > oldCount {
                    showSuggestions = false // hide suggestions on new message
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.streamingText) { _, newText in
                if !newText.isEmpty {
                    DispatchQueue.main.async {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
            // Detect scroll-up to reveal suggestions (Fix 17)
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    Color.clear
                        .preference(key: ScrollOffsetKey.self,
                            value: geo.frame(in: .named("scrollSpace")).minY)
                }
                .frame(height: 0)
            }
        }
        .coordinateSpace(name: "scrollSpace")
        .onPreferenceChange(ScrollOffsetKey.self) { offset in
            // When content is scrolled up (offset < -120), reveal suggestions
            withAnimation(.easeInOut(duration: 0.2)) {
                showSuggestions = offset < -120
            }
        }
    }

    // Scroll offset preference key (Fix 17)
    struct ScrollOffsetKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    /// Contextual suggestion chips — revealed when user scrolls up past newest content (Fix 17)
    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(currentSuggestions, id: \.self) { suggestion in
                    Button {
                        viewModel.sendInternalMessage(suggestion)
                        showSuggestions = false
                    } label: {
                        Text(suggestion)
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// Context-aware suggestions based on current chat context and project
    private var currentSuggestions: [String] {
        var suggestions: [String] = []

        switch viewModel.activeContext {
        case .project:
            if let name = viewModel.activeProjectName {
                suggestions.append("Summarize \(name)")
                suggestions.append("Tasks due this week in \(name)")
                suggestions.append("Recent changes in \(name)")
            }
            suggestions.append("List all tasks")
            suggestions.append("Show project health")
        case .global:
            suggestions.append("What projects do I have?")
            suggestions.append("Find recent items")
            suggestions.append("Create a new note")
        case .inbox:
            suggestions.append("Process my inbox")
            suggestions.append("Find items to review")
        case .exploreProjects:
            suggestions.append("Compare project health")
            suggestions.append("Find overdue tasks")
        case .item:
            suggestions.append("Analyze this item")
            suggestions.append("Summarize key points")
        }

        return Array(suggestions.prefix(6))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Ask anything about your knowledge")
                .font(.title3).fontWeight(.medium)
            Text("Your AI assistant can search, read, and explore your audio recordings, notes, projects, and connections.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Input bar

    private var chatInputBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // Voice dictation button — polished
            Button {
                if isDictating { finishDictation() } else { startDictation() }
            } label: {
                ZStack {
                    // Pulse ring during recording
                    if dictationPhase == .recording {
                        Circle()
                            .stroke(.red.opacity(0.3), lineWidth: 2)
                            .frame(width: 44, height: 44)
                            .scaleEffect(1.0 + 0.15 * sin(dictationElapsed * 4))
                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: dictationElapsed)
                    }
                    // Icon
                    Group {
                        switch dictationPhase {
                        case .idle:
                            Image(systemName: "mic").font(.body).foregroundStyle(.secondary)
                        case .recording:
                            Image(systemName: "mic.fill").font(.body).foregroundStyle(.red)
                        case .transcribing:
                            ProgressView().scaleEffect(0.7).tint(.orange)
                        case .done:
                            Image(systemName: "checkmark.circle.fill").font(.body).foregroundStyle(.green)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(dictationPhase == .recording ? Color.red.opacity(0.08) : Color.clear)
                    .clipShape(Circle())
                }
            }
            .disabled(dictationPhase == .transcribing)

            TextField("Ask anything...", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($isInputFocused)

            if viewModel.state == .thinking || viewModel.state == .streaming {
                Button {
                    viewModel.cancelStreaming()
                    isInputFocused = false
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    viewModel.sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.3) : Color.blue)
                }
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, compact ? 4 : 8)
        .padding(.bottom, compact ? 0 : 8)
        .background(.bar)
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Dictation

    private func startDictation() {
        guard !isDictating else { return }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { self.startDictation() }
                    else { self.dictationError = "Microphone access denied. Enable in Settings." }
                }
            }
            return
        case .denied:
            dictationError = "Microphone access denied. Enable in Settings > Privacy > Microphone."
            return
        case .granted: break
        @unknown default: break
        }

        isDictating = true
        dictationError = nil
        dictationElapsed = 0
        dictationPhase = .recording

        // Start audio recorder
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            self.audioRecorder = recorder
        } catch {
            dictationError = "Could not start recording."
            dictationPhase = .idle
            isDictating = false
            return
        }

        // Timer for visual feedback (waveform, elapsed)
        dictationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                self.dictationElapsed += 0.1
                if let r = self.audioRecorder, r.isMeteringEnabled {
                    r.updateMeters()
                    self.dictationLevel = (r.averagePower(forChannel: 0) + 40) / 40
                }
                // Safety: auto-stop at 60 seconds
                if self.dictationElapsed >= 60 {
                    self.finishDictation()
                }
            }
        }
    }

    /// User tapped stop — finish recording and transcribe.
    private func finishDictation() {
        dictationTimer?.invalidate()
        dictationTimer = nil
        audioRecorder?.stop()
        let recordedURL = audioRecorder?.url
        audioRecorder = nil

        guard let audioURL = recordedURL else {
            dictationPhase = .idle
            isDictating = false
            dictationError = "Recording failed. Please try again."
            return
        }

        dictationPhase = .transcribing
        dictationTask?.cancel()
        dictationTask = Task {
            let text = await transcribeAudio(audioURL)
            try? FileManager.default.removeItem(at: audioURL)

            await MainActor.run {
                dictationTimer?.invalidate()
                dictationTimer = nil
                if let text, !text.isEmpty {
                    viewModel.inputText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    dictationError = nil
                    dictationPhase = .done
                } else if !Task.isCancelled {
                    dictationError = "Couldn't transcribe audio. Check your network or try again."
                    dictationPhase = .idle
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if dictationPhase == .done { dictationPhase = .idle }
                }
                isDictating = false
            }
        }
    }

    private func transcribeAudio(_ audioURL: URL) async -> String? {
        // Try Whisper first
        if let result = await transcribeViaWhisperWithFile(audioURL) {
            return result
        }
        // Fallback: Apple on-device with the same file
        guard !Task.isCancelled else { return nil }
        return await recognizeFile(audioURL)
    }

    private func transcribeViaWhisperWithFile(_ audioURL: URL) async -> String? {
        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
              config.type == .openAI || config.type == .openAICompatible,
              let baseURL = config.baseURL else { return nil }
        guard !Task.isCancelled else { return nil }

        var apiKey = ""
        if let keyId = config.apiKeyKeychainIdentifier {
            apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
        }
        guard !apiKey.isEmpty else { return nil }

        let engine = RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
        do {
            let transcript = try await engine.transcribeFile(audioURL)
            guard !Task.isCancelled else { return nil }
            return transcript.segments.map(\.text).joined(separator: " ")
        } catch { return nil }
    }

    /// Start recording freely — returns audio URL when user taps stop.
    private func captureAudioChunk() async -> URL? {
        // This is now only used internally; finishDictation handles the real flow.
        await withCheckedContinuation { continuation in
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictation_\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            var hasResumed = false
            do {
                let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
                recorder.isMeteringEnabled = true
                self.audioRecorder = recorder
                recorder.record(forDuration: 60) // max safety
                // The recorder stops itself at 60s
                // But finishDictation() is called by the UI button before then
                Task {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    if !hasResumed {
                        hasResumed = true
                        recorder.stop()
                        self.audioRecorder = nil
                        continuation.resume(returning: audioURL)
                    }
                }
            } catch {
                if !hasResumed { hasResumed = true; continuation.resume(returning: nil) }
            }
        }
    }



    private func captureAppleAudioURL() async -> URL? {
        // SFSpeechRecognizer can work with audio files.
        // Re-record a short clip in a format it handles well.
        await withCheckedContinuation { continuation in
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple_dictation_\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
            var hasResumed = false
            do {
                let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
                recorder.isMeteringEnabled = true
                self.audioRecorder = recorder
                recorder.record()
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if !hasResumed {
                        hasResumed = true
                        recorder.stop()
                        self.audioRecorder = nil
                        continuation.resume(returning: audioURL)
                    }
                }
            } catch {
                if !hasResumed { hasResumed = true; continuation.resume(returning: nil) }
            }
        }
    }

    private func recognizeFile(_ url: URL) async -> String? {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if error != nil || result?.isFinal == true {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: result?.bestTranscription.formattedString)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    private func recognizeLive() async -> String? {
        await withCheckedContinuation { continuation in
            let recognizer = SFSpeechRecognizer()
            guard let recognizer, recognizer.isAvailable else {
                continuation.resume(returning: nil)
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let engine = AVAudioEngine()
            self.audioEngine = engine // Store for proper cleanup
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            var resultText: String?
            var resumed = false

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            do { try engine.start() } catch { continuation.resume(returning: nil); return }

            recognizer.recognitionTask(with: request) { result, error in
                if let result { resultText = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true {
                    guard !resumed else { return }
                    resumed = true
                    engine.stop()
                    inputNode.removeTap(onBus: 0)
                    continuation.resume(returning: resultText)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !resumed else { return }
                resumed = true
                engine.stop()
                inputNode.removeTap(onBus: 0)
                continuation.resume(returning: resultText)
            }
        }
    }


    private func stopDictation() {
        dictationTimer?.invalidate()
        dictationTimer = nil
        dictationTask?.cancel()
        dictationTask = nil
        audioRecorder?.stop()
        audioRecorder = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isDictating = false
        dictationPhase = .idle
    }
}

// MARK: - Message bubble

// MARK: - Thinking Bubble (collapsible)

struct ThinkingBubble: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption).foregroundStyle(.purple)
                    Text("Thinking...").font(.caption).foregroundStyle(.purple)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.3))
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, 1)
        }
    }
}

// MARK: - Message bubble

struct ChatMessageBubbleView: View {
    let message: ChatMessage
    var projectColorHex: String? = nil

    private var effectiveColor: Color {
        if let hex = projectColorHex ?? message.projectColorHex {
            return Color(hex: hex)
        }
        return .blue
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user { Spacer(minLength: 60) }
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                    if message.isThinking == true {
                        ThinkingBubble(text: message.content)
                    } else if message.content.count < 500,
                       let attr = try? AttributedString(markdown: message.content) {
                        Text(attr)
                            .font(.body)
                            .foregroundStyle(message.role == .user ? .white : .primary)
                            .textSelection(.enabled)
                    } else {
                        Text(message.content)
                            .font(.body)
                            .foregroundStyle(message.role == .user ? .white : .primary)
                            .textSelection(.enabled)
                    }

                    if let citations = message.citations, !citations.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(citations, id: \.itemId) { c in
                                    NavigationLink(value: c.itemId) {
                                        HStack(spacing: 4) {
                                            if let hex = c.projectColorHex {
                                                Circle()
                                                    .fill(Color(hex: hex))
                                                    .frame(width: 6, height: 6)
                                            }
                                            Image(systemName: c.itemType.icon).font(.caption2).foregroundStyle(c.itemType.color)
                                            Text(c.title).font(.caption2).lineLimit(1)
                                            Image(systemName: "arrow.up.right").font(.system(size: 7))
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(message.role == .user ? effectiveColor : Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .leading) {
                    if message.role == .assistant, projectColorHex ?? message.projectColorHex != nil {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(effectiveColor.opacity(0.4))
                            .frame(width: 3)
                            .padding(.vertical, 10)
                            .padding(.leading, 1)
                    }
                }
                if message.role != .user { Spacer(minLength: 60) }
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Agent Status Bar (compact, unified working indicator)

/// A single compact bar showing agent activity — replaces individual tool call cards.
/// Collapsed by default; tap to expand and see individual tool details.
struct AgentStatusBar: View {
    let state: ChatViewModel.ChatState
    let toolCalls: [ToolCallProgress]
    @State private var expanded = false

    private var runningCount: Int { toolCalls.filter { $0.status == .running }.count }
    private var completedCount: Int { toolCalls.filter { $0.status == .completed }.count }
    private var failedCount: Int { toolCalls.filter { $0.status == .failed }.count }
    private var totalCount: Int { toolCalls.count }

    var body: some View {
        if totalCount == 0 && state != .thinking { EmptyView() } else {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        // Status icon
                        if state == .thinking && totalCount == 0 {
                            ProgressView().scaleEffect(0.55)
                            Text("Thinking...").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            if runningCount > 0 {
                                ProgressView().scaleEffect(0.55)
                            } else if failedCount > 0 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9)).foregroundStyle(.orange)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9)).foregroundStyle(.green)
                            }
                            // Compact summary
                            Text("\(totalCount) tool\(totalCount == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                            if runningCount > 0 {
                                Text("· \(runningCount) running").font(.caption2).foregroundStyle(.tertiary)
                            }
                            if failedCount > 0 {
                                Text("· \(failedCount) failed").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if totalCount > 0 {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial)
                .padding(.horizontal, 16)

                if expanded && totalCount > 0 {
                    VStack(spacing: 1) {
                        ForEach(toolCalls.suffix(6), id: \.id) { tc in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(tc.status == .completed ? .green : tc.status == .failed ? .red : .orange)
                                    .frame(width: 4, height: 4)
                                Text(tc.toolName).font(.caption2).foregroundStyle(.secondary)
                                if let summary = tc.displaySummary {
                                    Text("—").font(.caption2).foregroundStyle(.tertiary)
                                    Text(summary).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20).padding(.vertical, 1)
                        }
                        if totalCount > 6 {
                            Text("... \(totalCount - 6) more").font(.caption2).foregroundStyle(.tertiary)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Tool call card (deprecated — kept for reference)

struct ToolCallCardView: View {
    let progress: ToolCallProgress

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: progress.status == .running ? "hourglass" : (progress.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .font(.caption)
                .foregroundColor(progress.status == .running ? .orange : (progress.status == .completed ? .green : .red))

            Text(progress.toolName)
                .font(.caption).fontWeight(.medium)

            if let summary = progress.displaySummary {
                Text("·").font(.caption).foregroundStyle(.secondary)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }
}

// MARK: - Streaming message

struct StreamingMessageView: View {
    let text: String
    var projectColorHex: String? = nil

    private var cursorColor: Color {
        if let hex = projectColorHex { return Color(hex: hex) }
        return .blue
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                    Text(" ▌")
                        .foregroundColor(cursorColor)
                }
            }
            .padding(12)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Conversation list

// MARK: - Share

@MainActor
private func shareConversation(viewModel: ChatViewModel) {
    let messages = viewModel.messages
    guard !messages.isEmpty else { return }
    let title = viewModel.currentConversation?.title ?? "Chat"
    var text = "# \(title)\n\n"
    for msg in messages {
        let role = msg.role == .user ? "You" : (msg.role == .assistant ? "Wawa" : "[\(msg.role.rawValue)]")
        text += "**\(role):** \(msg.content)\n\n"
    }
    let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let root = scene.windows.first?.rootViewController {
        root.present(av, animated: true)
    }
}

// MARK: - Conversations List

struct ConversationListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.conversations.isEmpty {
                    VStack(spacing: 16) {
                        Spacer().frame(height: 60)
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("No conversations yet").font(.headline)
                        Text("Start a new conversation in the Chat tab.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(groupedConversations, id: \.title) { group in
                            Section {
                                ForEach(group.conversations) { conv in
                                    Button {
                                        viewModel.selectConversation(conv)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 4) {
                                                Text(conv.title.isEmpty ? "New conversation" : conv.title)
                                                    .font(.subheadline).fontWeight(.medium).lineLimit(1)
                                                Spacer()
                                                if conv.id == viewModel.currentConversation?.id {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.caption).foregroundStyle(.blue)
                                                }
                                            }
                                            HStack {
                                                if let preview = conv.lastMessagePreview {
                                                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                                Spacer()
                                                Text(conv.updatedAt, style: .relative)
                                                    .font(.caption2).foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .swipeActions {
                                        Button("Delete", role: .destructive) {
                                            viewModel.deleteConversation(conv)
                                        }
                                    }
                                }
                            } header: {
                                Label(group.title, systemImage: group.icon)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func contextLabel(for key: String) -> (icon: String, label: String)? {
        if key == "global" { return ("globe", "General") }
        if key == "inbox" { return ("tray", "Inbox") }
        if key == "explore:projects" { return ("folder", "Projects") }
        if key.hasPrefix("project:") { return ("rectangle.stack", "Project") }
        if key.hasPrefix("item:") { return ("doc", "Item") }
        return nil
    }

    private var groupedConversations: [(title: String, icon: String, conversations: [ChatConversation])] {
        let groups: [(String, String, (ChatConversation) -> Bool)] = [
            ("Current Context", "pin", { $0.contextKey == viewModel.activeContext.key }),
            ("Projects", "rectangle.stack", { $0.contextKey?.hasPrefix("project:") == true }),
            ("Items", "doc", { $0.contextKey?.hasPrefix("item:") == true }),
            ("Other", "ellipsis", { _ in true })
        ]
        return groups.compactMap { (title, icon, filter) in
            let filtered = viewModel.conversations.filter(filter)
            guard !filtered.isEmpty else { return nil }
            return (title, icon, filtered)
        }
    }
}

// MARK: - Pipeline Progress Card

struct PipelineProgressCardView: View {
    let status: PipelineProgress
    @State private var expanded = false

    private var color: Color {
        switch status.phase {
        case "completed": return .green
        case "error": return .red
        default: return .blue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if status.phase == "processing" {
                        ProgressView().scaleEffect(0.55)
                    } else {
                        Image(systemName: status.phase == "completed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 9)).foregroundStyle(color)
                    }
                    Text("Pipeline: \(status.itemTitle)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let tool = status.currentTool {
                        Text("· \(tool)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    if !status.toolLog.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .padding(.horizontal, 16)

            if expanded && !status.toolLog.isEmpty {
                VStack(spacing: 1) {
                    ForEach(status.toolLog, id: \.self) { entry in
                        HStack(spacing: 4) {
                            Circle().fill(color).frame(width: 4, height: 4)
                            Text(entry).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

// MARK: - Parsed Message View

/// Parses message content through ContentParser and renders as native blocks.
/// Falls back to plain text if no blocks are extracted.
struct ParsedMessageView: View {
    let message: ChatMessage
    var projectColorHex: String? = nil
    var onSendMessage: ((String) -> Void)?
    var onRunCommand: ((String) -> Void)?
    var onChooseOption: ((String) -> Void)?

    var body: some View {
        Group {
            // 0. Thinking messages — collapsible, distinct visual style
            if message.isThinking == true {
                ThinkingBubble(text: message.content)
            }
            // 1. Structured blocks from ShellInterpreter (touch, ls, etc.)
            else if let blocks = message.blocks, !blocks.isEmpty {
                blocksView(blocks)
            }
            // 2. Smart parser: detect patterns in text → interactive blocks
            else if !smartBlocks.isEmpty {
                blocksView(smartBlocks)
            }
            // 3. Fallback: markdown parser
            else if !parsedBlocks.isEmpty, !(parsedBlocks.count == 1 && message.role == .assistant) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(parsedBlocks) { block in
                        switch block {
                        case .text(let t): Text(t).font(.body)
                        case .bulletList(let items): ForEach(items, id: \.self) { Text("• \($0)").font(.body) }
                        case .orderedList(let items): ForEach(Array(items.enumerated()), id: \.offset) { i, item in Text("\(i+1). \(item)").font(.body) }
                        case .code(let c): Text(c.code).font(.caption).monospaced()
                        default: Text(String(describing: block)).font(.body)
                        }
                    }
                }
                .padding(12).background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            // 4. Plain text bubble
            else {
                ChatMessageBubbleView(message: message, projectColorHex: projectColorHex)
            }
        }
    }

    private var smartBlocks: [ChatBlock] {
        SmartBlockParser.parse(message.content, role: message.role)
    }
    private var parsedBlocks: [OutputBlock] {
        ContentParser.parse(message.content).0
    }

    private func blocksView(_ blocks: [ChatBlock]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ChatBlockView(block: block, projectColorHex: projectColorHex,
                    onSendMessage: onSendMessage, onRunCommand: onRunCommand, onChooseOption: onChooseOption)
            }
        }
        .padding(12).background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Smart Block Parser

/// Detects markdown patterns in agent text and upgrades them to interactive UI blocks.
enum SmartBlockParser {
    static func parse(_ text: String, role: AIRole) -> [ChatBlock] {
        guard role == .assistant || role == .tool else { return [] }
        let blocks = extractBlocks(text)
        if blocks.count >= 2 || blocks.containsNonText { return blocks }
        return detectInlineCards(text)
    }

    private static func extractBlocks(_ text: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        let lines = text.components(separatedBy: "\n")
        var currentSection: (title: String, content: [String])?
        var preamble: [String] = []

        func flush() {
            guard let section = currentSection else { return }
            let content = section.content.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !content.isEmpty else { currentSection = nil; return }
            if let tasks = detectCheckboxTasks(section.content), !tasks.isEmpty {
                blocks.append(contentsOf: tasks)
            } else if let choice = detectChoicePrompt(section.content) {
                blocks.append(.choicePrompt(choice))
            } else {
                blocks.append(.text("**" + section.title + "**\n" + content.joined(separator: "\n")))
            }
            currentSection = nil
        }

        for line in lines {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            if cleaned.hasPrefix("## ") || cleaned.hasPrefix("# ") {
                flush()
                currentSection = (title: cleaned.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces), content: [])
            } else if cleaned.hasPrefix("**") && cleaned.contains(":**") {
                flush()
                let title = cleaned.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
                currentSection = (title: title, content: [])
            } else if currentSection != nil {
                currentSection!.content.append(cleaned)
            } else {
                preamble.append(cleaned)
            }
        }
        flush()

        if !preamble.isEmpty {
            if let choice = detectChoicePrompt(preamble) { blocks.insert(.choicePrompt(choice), at: 0) }
            else if let tasks = detectCheckboxTasks(preamble), !tasks.isEmpty { blocks.insert(contentsOf: tasks, at: 0) }
            else if let confirm = detectConfirmation(preamble.joined(separator: "\n")) { blocks.append(.confirmation(confirm)) }
        }
        return blocks
    }

    private static func detectInlineCards(_ text: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        if let confirm = detectConfirmation(text) { blocks.append(.confirmation(confirm)) }
        return blocks
    }

    private static func detectChoicePrompt(_ lines: [String]) -> ChoicePromptData? {
        let numbered = lines.filter { line in
            guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
            return first.isNumber && (line.contains(". ") || line.contains(") "))
        }
        guard numbered.count >= 2 else { return nil }
        let questionLine = lines.first { !numbered.contains($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Choose:"
        let options = numbered.compactMap { line -> ChoiceOption? in
            var s = line.trimmingCharacters(in: .whitespaces)
            while let f = s.first, f.isNumber || f == "." || f == ")" || f == "-" || f == " " { s.removeFirst() }
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : ChoiceOption(label: t, value: t)
        }
        return options.count >= 2 ? ChoicePromptData(question: String(questionLine.prefix(150)), options: options) : nil
    }

    private static func detectCheckboxTasks(_ lines: [String]) -> [ChatBlock]? {
        let tasks = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- [ ]") || t.hasPrefix("* [ ]") || t.hasPrefix("- [x]") || t.hasPrefix("* [x]")
        }
        guard !tasks.isEmpty else { return nil }
        return tasks.compactMap { line -> ChatBlock? in
            let t = line.trimmingCharacters(in: .whitespaces)
            let done = t.hasPrefix("- [x]") || t.hasPrefix("* [x]")
            let title = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return .taskCard(TaskCardData(taskID: UUID().uuidString, title: title, status: done ? "done" : "todo", priority: "medium", owner: nil, projectSlug: nil, needsConfirmation: !done))
        }
    }

    private static func detectConfirmation(_ text: String) -> ConfirmationData? {
        let lower = text.lowercased()
        guard lower.contains("warning") || lower.contains("are you sure") || lower.contains("delete?") || lower.contains("confirm") else { return nil }
        let first = text.components(separatedBy: "\n").first ?? text
        return ConfirmationData(title: "Please confirm", message: String(first.prefix(200)), confirmLabel: "Yes, proceed", cancelLabel: "Cancel", confirmValue: "yes", cancelValue: "cancel")
    }
}

extension Array where Element == ChatBlock {
    var containsNonText: Bool { contains { if case .text = $0 { false } else { true } } }
}
// MARK: - Output Block Renderer

/// Renders parsed OutputBlocks as native SwiftUI components.
/// Falls back to text if the block type is unknown.
struct OutputBlockRenderer: View {
    let block: OutputBlock

    var body: some View {
        switch block {
        case .text(let content):
            Text(content).font(.body)

        case .table(let table):
            TableBlockView(table: table)

        case .actions(let actions):
            ActionBlockView(actions: actions)

        case .card(let card):
            CardBlockView(card: card)

        case .bulletList(let items):
            BulletListView(items: items)

        case .orderedList(let items):
            OrderedListView(items: items)

        case .code(let codeBlock):
            CodeBlockView(codeBlock: codeBlock)
        }
    }
}

// MARK: - Table View


// MARK: - Action Block View


// MARK: - Card Block View


// MARK: - Bullet & Ordered List Views



// MARK: - Code Block View


/// Wraps KnowledgeDetailView for NavigationLink destination, loading the item from context.

// MARK: - Phase F: Evidence & Confidence



// MARK: - Chat Block Renderer

struct ChatBlockView: View {
    let block: ChatBlock
    var projectColorHex: String?
    var onSendMessage: ((String) -> Void)?
    var onRunCommand: ((String) -> Void)?
    var onChooseOption: ((String) -> Void)?

    var body: some View {
        switch block {
        case .text(let text):
            Text(text).font(.body)
        case .table(let data):
            TableBlockView(table: TableBlock(title: data.title, headers: data.headers, rows: data.rows))
        case .code(let data):
            CodeBlockView(codeBlock: CodeBlock(code: data.code, language: data.language, caption: data.caption))
        case .bulletList(let items):
            BulletListView(items: items)
        case .orderedList(let items):
            OrderedListView(items: items)
        case .projectContext(let ctx):
            ProjectContextCardView(data: ctx, onRunCommand: onRunCommand)
        case .taskCard(let task):
            TaskCardView(data: task, onRunCommand: onRunCommand, onChooseOption: onChooseOption)
        case .itemCard(let item):
            ItemCardView(data: item, onRunCommand: onRunCommand, onChooseOption: onChooseOption)
        case .searchResults(let results):
            SearchResultsCardView(data: results)
        case .analysisAccordion(let analysis):
            AnalysisAccordionView(data: analysis)
        case .choicePrompt(let prompt):
            ChoicePromptView(data: prompt, onChooseOption: onChooseOption)
        case .confirmation(let confirm):
            ConfirmationView(data: confirm, onChooseOption: onChooseOption)
        }
    }
}

// MARK: - Project Context Card

struct ProjectContextCardView: View {
    let data: ProjectContextData
    var onRunCommand: ((String) -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 4).fill(Color.blue).frame(width: 4, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.projectName).font(.subheadline).fontWeight(.semibold)
                    HStack(spacing: 8) {
                        HStack(spacing: 3) { Image(systemName: "checklist").font(.system(size: 9)); Text("\(data.taskCount)").font(.caption2) }.foregroundStyle(.secondary)
                        HStack(spacing: 3) { Image(systemName: "doc").font(.system(size: 9)); Text("\(data.itemCount)").font(.caption2) }.foregroundStyle(.secondary)
                        if data.signalCount > 0 {
                            HStack(spacing: 3) { Image(systemName: "waveform.path.ecg").font(.system(size: 9)); Text("\(data.signalCount)").font(.caption2) }.foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
            }
            if expanded {
                Divider().padding(.vertical, 6)
                HStack(spacing: 6) {
                    ForEach(["ls tasks/", "ls items/", "cat project.json"], id: \.self) { cmd in
                        Button { onRunCommand?(cmd) } label: {
                            Text(cmd).font(.caption2).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.ultraThinMaterial).clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 2) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    Text(expanded ? "Less" : "Actions").font(.caption2)
                }.foregroundStyle(.blue)
            }.buttonStyle(.plain).padding(.top, 4)
        }
        .padding(12)
        .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Task Card

/// Swipeable task card with direct actions (no model needed for status changes)
/// and model-driven actions (view details, suggest next steps).
struct TaskCardView: View {
    let data: TaskCardData
    var onRunCommand: ((String) -> Void)?
    var onChooseOption: ((String) -> Void)?
    @State private var confirmed = false
    @State private var dismissed = false
    @State private var showActions = false
    @State private var offsetX: CGFloat = 0

    private let swipeThreshold: CGFloat = -80

    var body: some View {
        if dismissed { EmptyView() } else {
            ZStack {
                // Swipe-revealed action buttons (behind the card)
                HStack(spacing: 0) {
                    Spacer()
                    // Direct action: mark done (no model needed)
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            confirmed = true
                            offsetX = 0
                        }
                        let path = "tasks/\(data.taskID)"
                        onRunCommand?("echo '{\"status\":\"done\"}' > \(path)")
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").font(.title3)
                            Text("Done").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 70)
                        .frame(maxHeight: .infinity)
                        .background(Color.green)
                    }
                    // Model-driven action: view details
                    Button {
                        withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                        onChooseOption?("Show me details about the task: \(data.title)")
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "info.circle.fill").font(.title3)
                            Text("Details").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 70)
                        .frame(maxHeight: .infinity)
                        .background(Color.blue)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Main card
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: confirmed ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(confirmed ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(data.title).font(.subheadline).fontWeight(.semibold)
                            HStack(spacing: 6) {
                                priorityBadge(data.priority)
                                if let o = data.owner { Text(o).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer()
                        if confirmed {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
                        }
                        // Swipe hint
                        if !confirmed && !showActions {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .opacity(offsetX < -20 ? 0 : 0.4)
                        }
                    }
                    if !confirmed && data.needsConfirmation && !showActions {
                        HStack(spacing: 8) {
                            Button {
                                confirmed = true
                                let path = "tasks/\(data.taskID)"
                                onRunCommand?("echo '{\"status\":\"done\"}' > \(path)")
                            } label: {
                                Label("Confirm", systemImage: "checkmark").font(.caption2).fontWeight(.medium)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                            Button { dismissed = true } label: {
                                Label("Cancel", systemImage: "xmark").font(.caption2)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }
                }
                .padding(12)
                .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                .offset(x: offsetX)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard !confirmed else { return }
                            let translation = value.translation.width
                            if translation < 0 {
                                offsetX = max(translation, -150)
                            } else if offsetX < 0 {
                                offsetX = min(translation + offsetX, 0)
                            }
                        }
                        .onEnded { value in
                            guard !confirmed else { return }
                            let velocity = value.predictedEndTranslation.width - value.translation.width
                            if offsetX < swipeThreshold || velocity < -200 {
                                withAnimation(.spring(response: 0.3)) { offsetX = -140 }
                                showActions = true
                            } else {
                                withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                                showActions = false
                            }
                        }
                )
            }
        }
    }

    func priorityBadge(_ p: String) -> some View {
        let (color, icon): (Color, String) = {
            switch p {
            case "critical": (.red, "exclamationmark.triangle.fill")
            case "high": (.orange, "arrow.up")
            case "medium": (.blue, "minus")
            default: (.secondary, "minus")
            }
        }()
        return HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8))
            Text(p.capitalized).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12)).clipShape(Capsule())
        .foregroundStyle(color)
    }
}

// MARK: - Item Card

/// Swipeable item card with direct and model-driven actions.
struct ItemCardView: View {
    let data: ItemCardData
    var onRunCommand: ((String) -> Void)?
    var onChooseOption: ((String) -> Void)?
    @State private var offsetX: CGFloat = 0
    @State private var showActions = false

    private let swipeThreshold: CGFloat = -80

    var body: some View {
        ZStack {
            // Swipe-revealed action buttons
            HStack(spacing: 0) {
                Spacer()
                // View details via model
                Button {
                    withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                    onChooseOption?("Show me details about: \(data.title)")
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "info.circle.fill").font(.title3)
                        Text("Details").font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 70)
                    .frame(maxHeight: .infinity)
                    .background(Color.blue)
                }
                // Analyze via pipeline
                if let uuid = UUID(uuidString: data.itemID) {
                    Button {
                        withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                        NotificationCenter.default.post(name: .pipelineCompleted, object: data.itemID,
                            userInfo: ["action": "reprocess"])
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.title3)
                            Text("Analyze").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 70)
                        .frame(maxHeight: .infinity)
                        .background(Color.purple)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Main card
            HStack(spacing: 10) {
                Image(systemName: typeIcon(data.type)).font(.title3).foregroundStyle(typeColor(data.type))
                    .frame(width: 32).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(data.type.capitalized).font(.caption2).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(data.status.capitalized).font(.caption2).foregroundStyle(.secondary)
                        if let dur = data.durationSeconds { Text("·").foregroundStyle(.tertiary); Text(formatDuration(dur)).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                // Swipe hint
                if !showActions {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .opacity(offsetX < -20 ? 0 : 0.4)
                }
            }
            .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
            .offset(x: offsetX)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let translation = value.translation.width
                        if translation < 0 {
                            offsetX = max(translation, -150)
                        } else if offsetX < 0 {
                            offsetX = min(translation + offsetX, 0)
                        }
                    }
                    .onEnded { value in
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        if offsetX < swipeThreshold || velocity < -200 {
                            withAnimation(.spring(response: 0.3)) { offsetX = -140 }
                            showActions = true
                        } else {
                            withAnimation(.spring(response: 0.3)) { offsetX = 0 }
                            showActions = false
                        }
                    }
            )
        }
    }
    private func typeIcon(_ t: String) -> String {
        switch t { case "audio": "mic.fill"; case "note": "doc.text.fill"; case "image": "photo.fill"; default: "doc.fill" }
    }
    private func typeColor(_ t: String) -> Color {
        switch t { case "audio": .red; case "note": .blue; case "image": .purple; default: .secondary }
    }
    private func formatDuration(_ s: Double) -> String { let m = Int(s)/60; let sec = Int(s)%60; return "\(m):\(String(format:"%02d",sec))" }
}

// MARK: - Search Results

struct SearchResultsCardView: View {
    let data: SearchResultsData
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\"\(data.query)\" — \(data.results.count) results", systemImage: "magnifyingglass")
                .font(.subheadline).fontWeight(.medium).foregroundStyle(.blue)
            ForEach(data.results.prefix(5), id: \.itemID) { r in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.caption).fontWeight(.medium).lineLimit(1)
                        Text(r.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Analysis Accordion

struct AnalysisAccordionView: View {
    let data: AnalysisData
    var body: some View {
        VStack(spacing: 0) {
            ForEach(data.sections, id: \.title) { section in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(section.items.prefix(10), id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(.secondary).frame(width: 4, height: 4).padding(.top, 7)
                                Text(item).font(.caption).foregroundStyle(.primary)
                            }
                        }
                        if section.items.count > 10 {
                            Text("... and \(section.items.count - 10) more").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.padding(.leading, 4).padding(.top, 2)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sectionIcon(section.title)).font(.system(size: 10)).foregroundStyle(.blue)
                        Text(section.title).font(.caption).fontWeight(.semibold)
                        Text("(\(section.count))").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 3)
                if section.title != data.sections.last?.title { Divider().padding(.leading, 22) }
            }
        }
        .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func sectionIcon(_ t: String) -> String {
        switch t.lowercased() {
        case let s where s.contains("decision"): "checkmark.shield"
        case let s where s.contains("action"): "bolt"
        case let s where s.contains("risk"): "exclamationmark.triangle"
        case let s where s.contains("question"): "questionmark.circle"
        case let s where s.contains("entit"): "person.2"
        default: "doc.text"
        }
    }
}

// MARK: - Choice Prompt

struct ChoicePromptView: View {
    let data: ChoicePromptData
    var onChooseOption: ((String) -> Void)?
    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(data.question).font(.subheadline).fontWeight(.semibold)
            ForEach(Array(data.options.enumerated()), id: \.offset) { idx, option in
                Button {
                    selectedIndex = idx
                    // Send the choice as a resolved prompt to the agent internally —
                    // the agent understands natural language and will process it.
                    let prompt = option.value
                    onChooseOption?(prompt)
                } label: {
                    HStack(spacing: 10) {
                        if let sel = selectedIndex, sel == idx {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                                .frame(width: 20, height: 20)
                        } else {
                            Text("\(idx + 1)").font(.caption).fontWeight(.bold).foregroundStyle(.blue)
                                .frame(width: 20, height: 20).background(Circle().fill(.blue.opacity(0.1)))
                        }
                        Text(option.label).font(.subheadline).lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(selectedIndex != nil && selectedIndex != idx ? 0.5 : 1.0)
                }.buttonStyle(.plain)
                .disabled(selectedIndex != nil)
            }
        }
        .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Confirmation

struct ConfirmationView: View {
    let data: ConfirmationData
    var onChooseOption: ((String) -> Void)?
    @State private var resolved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.title).font(.subheadline).fontWeight(.semibold)
                    Text(data.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            if !resolved {
                HStack(spacing: 8) {
                    Button {
                        resolved = true
                        onChooseOption?(data.confirmValue)
                    } label: {
                        Label(data.confirmLabel, systemImage: "checkmark").font(.caption).fontWeight(.medium)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    Button {
                        resolved = true
                        onChooseOption?(data.cancelValue)
                    } label: {
                        Text(data.cancelLabel).font(.caption).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Response sent").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

