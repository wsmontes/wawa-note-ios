import SwiftUI
import SwiftData
import Speech
import AVFoundation

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentPipeline: ContentPipelineService
    @StateObject private var viewModel = ChatViewModel()
    @State private var showConversations = false
    @FocusState private var isInputFocused: Bool
    @State private var isDictating = false
    @State private var dictationError: String?
    @State private var dictationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Project context banner (Phase H)
            if let projectName = viewModel.activeProjectName {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full").font(.caption).foregroundStyle(.blue)
                    Text(projectName).font(.caption).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Button {
                        viewModel.inputText = "Tell me about the status of project '\(projectName)'"
                        viewModel.sendMessage()
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
            messageList
                .navigationDestination(for: UUID.self) { itemID in
                    KnowledgeItemNavigationView(itemID: itemID)
                }
            if let dictErr = dictationError {
                HStack {
                    Image(systemName: "mic.slash").foregroundStyle(.red)
                    Text(dictErr).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { dictationError = nil }.font(.caption)
                }.padding(.horizontal, 12).padding(.vertical, 4).background(Color.red.opacity(0.08))
            }
            Divider()
            chatInputBar
        }
        .navigationTitle(viewModel.currentConversation?.title.isEmpty != false ? "Chat" : viewModel.currentConversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showConversations = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .accessibilityLabel("Conversations")
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
                    Button {
                        viewModel.createNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .accessibilityLabel("New conversation")
                    }
                }
            }
        }
        .sheet(isPresented: $showConversations) {
            ConversationListView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.setup(modelContext: modelContext)
            viewModel.loadConversations()
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Dismiss keyboard on tap in message area
                    Color.clear.frame(height: 0)
                        .contentShape(Rectangle())
                        .onTapGesture { isInputFocused = false }
                    if viewModel.messages.isEmpty && viewModel.streamingText.isEmpty {
                        emptyState
                    }

                    ForEach(viewModel.messages) { msg in
                        if msg.role == .assistant || msg.role == .tool {
                            ParsedMessageView(message: msg)
                                .id(msg.id)
                        } else {
                            ChatMessageBubbleView(message: msg)
                                .id(msg.id)
                        }
                    }

                    // Pipeline progress (from ContentPipelineService)
                    if let status = contentPipeline.pipelineStatus {
                        PipelineProgressCardView(status: status)
                    }

                    // Active tool calls
                    ForEach(viewModel.activeToolCalls, id: \.id) { tc in
                        ToolCallCardView(progress: tc)
                    }

                    // Streaming text
                    if !viewModel.streamingText.isEmpty {
                        StreamingMessageView(text: viewModel.streamingText)
                            .id("streaming")
                    }

                    if let error = viewModel.error {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Error", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                Spacer()
                                Button("Retry") { viewModel.sendMessage() }
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
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { isInputFocused = false }
            .onChange(of: viewModel.streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.activeToolCalls.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 80)
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
            Spacer()
        }
    }

    // MARK: - Input bar

    private var chatInputBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // Voice dictation button
            Button {
                if isDictating { stopDictation() } else { startDictation() }
            } label: {
                Image(systemName: isDictating ? "mic.fill" : "mic")
                    .font(.body)
                    .foregroundStyle(isDictating ? .red : .secondary)
                    .frame(width: 44, height: 44)
                    .background(isDictating ? Color.red.opacity(0.1) : Color.clear)
                    .clipShape(Circle())
            }

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
                    isInputFocused = false
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
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Dictation

    private func startDictation() {
        guard !isDictating else { return }
        isDictating = true

        dictationTask = Task {
            let text: String?
            // Try Whisper API first if available
            if let whisperText = await transcribeViaWhisper() {
                text = whisperText
            } else {
                // Fall back to Apple on-device
                text = await transcribeViaApple()
            }

            await MainActor.run {
                if let text, !text.isEmpty {
                    viewModel.inputText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    dictationError = nil
                } else if isDictating {
                    dictationError = "Dictation failed. Check microphone permission in Settings."
                }
                isDictating = false
            }
        }
    }

    private func transcribeViaWhisper() async -> String? {
        guard let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext),
              config.type == .openAI || config.type == .openAICompatible,
              let baseURL = config.baseURL else { return nil }

        var apiKey = ""
        if let keyId = config.apiKeyKeychainIdentifier {
            apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
        }
        guard !apiKey.isEmpty else { return nil }

        // Record a short audio chunk
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictation_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        guard let audioData = await captureAudioChunk() else { return nil }
        do {
            try audioData.write(to: audioURL)
        } catch { return nil }

        let engine = RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
        do {
            let transcript = try await engine.transcribeFile(audioURL)
            return transcript.segments.map(\.text).joined(separator: " ")
        } catch {
            return nil
        }
    }

    private func transcribeViaApple() async -> String? {
        await withCheckedContinuation { continuation in
            let recognizer = SFSpeechRecognizer()
            guard let recognizer, recognizer.isAvailable else {
                continuation.resume(returning: nil)
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false

            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            var resultText: String?
            var hasResumed = false

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let result { resultText = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true {
                    if !hasResumed {
                        hasResumed = true
                        audioEngine.stop()
                        inputNode.removeTap(onBus: 0)
                        continuation.resume(returning: resultText)
                    }
                }
            }

            // Timeout after 15 seconds
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !hasResumed {
                    hasResumed = true
                    audioEngine.stop()
                    inputNode.removeTap(onBus: 0)
                    continuation.resume(returning: resultText)
                }
            }
        }
    }

    private func captureAudioChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            var audioData = Data()
            var hasResumed = false

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                let channelData = buffer.floatChannelData?[0]
                if let channelData {
                    let frames = Int(buffer.frameLength)
                    let data = Data(bytes: channelData, count: frames * MemoryLayout<Float>.size)
                    audioData.append(data)
                }
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            // Stop after 10 seconds max
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !hasResumed {
                    hasResumed = true
                    audioEngine.stop()
                    inputNode.removeTap(onBus: 0)
                    continuation.resume(returning: audioData.isEmpty ? nil : audioData)
                }
            }
        }
    }

    private func stopDictation() {
        dictationTask?.cancel()
        dictationTask = nil
        isDictating = false
    }
}

// MARK: - Message bubble

struct ChatMessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user { Spacer(minLength: 60) }
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                    if message.isThinking == true {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7)
                            Text("Thinking...").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(message.role == .user ? .white : .primary)
                        .textSelection(.enabled)

                    if let citations = message.citations, !citations.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(citations, id: \.itemId) { c in
                                    NavigationLink(value: c.itemId) {
                                        HStack(spacing: 4) {
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
                .background(message.role == .user ? Color.blue : Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                if message.role != .user { Spacer(minLength: 60) }
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Tool call card

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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                    Text(" ▌")
                        .foregroundColor(.blue)
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
                        ForEach(viewModel.conversations) { conv in
                            Button {
                                viewModel.selectConversation(conv)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conv.title.isEmpty ? "New conversation" : conv.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                    HStack {
                                        if let preview = conv.lastMessagePreview { Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        Spacer()
                                        Text(conv.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { viewModel.deleteConversation(conv) } }
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
}

// MARK: - Pipeline Progress Card

struct PipelineProgressCardView: View {
    let status: PipelineProgress

    private var icon: String {
        switch status.phase {
        case "completed": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var color: Color {
        switch status.phase {
        case "completed": return .green
        case "error": return .red
        default: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(color)
                .opacity(status.phase == "processing" ? 1 : 0)

            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                Text("Agente: \(status.itemTitle)")
                    .font(.subheadline).fontWeight(.medium)
                if let tool = status.currentTool {
                    Text("Running \(tool)...")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let summary = status.toolSummary, !summary.isEmpty {
                    Text(summary).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                ForEach(status.toolLog, id: \.self) { entry in
                    Text(entry).font(.caption2).foregroundStyle(.blue).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.3)))
        .padding(.horizontal, 8)
        .transition(.opacity.combined(with: .scale))
        .animation(.easeInOut(duration: 0.2), value: status.phase)
    }
}

// MARK: - Parsed Message View

/// Parses message content through ContentParser and renders as native blocks.
/// Falls back to plain text if no blocks are extracted.
struct ParsedMessageView: View {
    let message: ChatMessage

    var body: some View {
        let (blocks, _) = ContentParser.parse(message.content)
        if blocks.isEmpty || (blocks.count == 1 && message.role == .assistant) {
            // Single text block or no blocks parsed → render as plain text bubble
            ChatMessageBubbleView(message: message)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    OutputBlockRenderer(block: block)
                }
            }
            .padding(12)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }
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

// MARK: - Action Block View

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

// MARK: - Card Block View

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

// MARK: - Bullet & Ordered List Views

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

// MARK: - Code Block View

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

/// Wraps KnowledgeDetailView for NavigationLink destination, loading the item from context.
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

// MARK: - Phase F: Evidence & Confidence

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
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
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
