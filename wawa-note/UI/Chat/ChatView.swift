import SwiftUI
import SwiftData
import Speech
import AVFoundation

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = ChatViewModel()
    @State private var showConversations = false
    @FocusState private var isInputFocused: Bool
    @State private var isDictating = false
    @State private var dictationError: String?
    @State private var dictationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            messageList
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
                        ChatMessageBubbleView(message: msg)
                            .id(msg.id)
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
            Text("Your AI assistant can search, read, and explore your meetings, notes, projects, and connections.")
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
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text").font(.caption2)
                                        Text(c.title).font(.caption2).lineLimit(1)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
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
