import SwiftUI
import SwiftData
import Speech
import AVFoundation
// Related JIRA: KAN-9, KAN-46, KAN-82


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
    @State private var showSuggestions = false
    @State private var isNearBottom = true
    @State private var dictation = DictationState()

    enum DictationPhase {
        case idle, recording, transcribing, done
    }

    /// Consolidated dictation state replacing 9 individual @State variables.
    struct DictationState {
        var isDictating = false
        var error: String?
        var task: Task<Void, Never>?
        var audioRecorder: AVAudioRecorder?
        var audioEngine: AVAudioEngine?
        var elapsed: Double = 0
        var level: Float = 0
        var phase: DictationPhase = .idle
        var timer: Timer?
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact {
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
                                HStack(spacing: 4) { ProgressView().scaleEffect(0.7); Text("Loading...").font(.caption2).foregroundStyle(.secondary) }
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
                .background(.thinMaterial)
            }
            if !compact || !viewModel.messages.isEmpty || !viewModel.streamingText.isEmpty {
                messageList
                    .navigationDestination(for: UUID.self) { itemID in
                        KnowledgeItemNavigationView(itemID: itemID)
                    }
                    .navigationDestination(for: String.self) { path in
                        FileBrowserView(initialPath: path)
                    }
            }
            // Suggestion bar — revealed when user scrolls up past newest content (Fix 17)
            if showSuggestions, !viewModel.messages.isEmpty {
                suggestionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Dictation recording status bar — free recording, user stops when done
            if dictation.phase == .recording {
                HStack(spacing: 10) {
                    // Pulsing red dot
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1.0 + 0.3 * sin(dictation.elapsed * 5))
                        .animation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true), value: dictation.elapsed)
                    // Audio level waveform
                    HStack(spacing: 2) {
                        ForEach(0..<10, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.red.opacity(0.5))
                                .frame(width: 2, height: CGFloat(4 + 14 * abs(sin(dictation.elapsed * 4 + Double(i) * 0.7))))
                                .animation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true), value: dictation.elapsed)
                        }
                    }
                    .frame(height: 18)
                    // Elapsed time counting UP
                    Text(formatElapsed(dictation.elapsed))
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
            if dictation.phase == .transcribing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Transcribing...").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }

            // Dictation error (works in both compact and full mode)
            if let dictErr = dictation.error {
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
                    Button("Dismiss") { dictation.error = nil }.font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.ultraThinMaterial)
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
        .onDisappear {
            stopDictation()
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
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
                                    Button { viewModel.error = nil } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .background(.red.opacity(0.12))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.red.opacity(0.4))
                                    .frame(width: 3)
                                    .padding(.vertical, 8)
                                    .padding(.leading, 2)
                            }
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
            .coordinateSpace(name: "scrollSpace")
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                if newCount > oldCount {
                    showSuggestions = false
                    if isNearBottom {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: viewModel.streamingText) { _, newText in
                if !newText.isEmpty, isNearBottom {
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
            // Scroll-to-bottom FAB — appears when user scrolls up
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom, !viewModel.messages.isEmpty {
                    Button {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                            isNearBottom = true
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .symbolRenderingMode(.hierarchical)
                            .background(Circle().fill(.regularMaterial))
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .onPreferenceChange(ScrollOffsetKey.self) { offset in
            // When content is scrolled up (offset < -60), reveal suggestions
            withAnimation(.easeInOut(duration: 0.2)) {
                showSuggestions = offset < -60
            }
            // Track whether user is near the bottom for auto-scroll decisions
            isNearBottom = offset > -200
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
        ChatInputBarView(
            inputText: $viewModel.inputText,
            isFocused: $isInputFocused,
            state: viewModel.state,
            compact: compact,
            dictationPhase: dictation.phase,
            dictationElapsed: dictation.elapsed,
            isDictating: dictation.isDictating,
            modelName: viewModel.selectedModel,
            onSend: { viewModel.sendMessage() },
            onCancel: { viewModel.cancelStreaming(); isInputFocused = false },
            onDictate: { if dictation.isDictating { finishDictation() } else { startDictation() } }
        )
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Dictation

    private func startDictation() {
        guard !dictation.isDictating else { return }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { self.startDictation() }
                    else { self.dictation.error = "Microphone access denied. Enable in Settings." }
                }
            }
            return
        case .denied:
            dictation.error = "Microphone access denied. Enable in Settings > Privacy > Microphone."
            return
        case .granted: break
        @unknown default: break
        }

        dictation.isDictating = true
        dictation.error = nil
        dictation.elapsed = 0
        dictation.phase = .recording

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
            self.dictation.audioRecorder = recorder
        } catch {
            dictation.error = "Could not start recording."
            dictation.phase = .idle
            dictation.isDictating = false
            return
        }

        // Timer for visual feedback (waveform, elapsed)
        dictation.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                self.dictation.elapsed += 0.1
                if let r = self.dictation.audioRecorder, r.isMeteringEnabled {
                    r.updateMeters()
                    self.dictation.level = (r.averagePower(forChannel: 0) + 40) / 40
                }
                // Safety: auto-stop at 60 seconds
                if self.dictation.elapsed >= 60 {
                    self.finishDictation()
                }
            }
        }
    }

    /// User tapped stop — finish recording and transcribe.
    private func finishDictation() {
        dictation.timer?.invalidate()
        dictation.timer = nil
        dictation.audioRecorder?.stop()
        let recordedURL = dictation.audioRecorder?.url
        dictation.audioRecorder = nil

        guard let audioURL = recordedURL else {
            dictation.phase = .idle
            dictation.isDictating = false
            dictation.error = "Recording failed. Please try again."
            return
        }

        dictation.phase = .transcribing
        dictation.task?.cancel()
        dictation.task = Task {
            let text = await transcribeAudio(audioURL)
            try? FileManager.default.removeItem(at: audioURL)

            await MainActor.run {
                dictation.timer?.invalidate()
                dictation.timer = nil
                if let text, !text.isEmpty {
                    viewModel.inputText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    dictation.error = nil
                    dictation.phase = .done
                } else if !Task.isCancelled {
                    dictation.error = "Couldn't transcribe audio. Check your network or try again."
                    dictation.phase = .idle
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if dictation.phase == .done { dictation.phase = .idle }
                }
                dictation.isDictating = false
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
              let baseURL = config.baseURL else { return nil }
        // Only use remote if the provider actually supports audio transcription
        let supportsTranscription = AIConfigService.shared.supportsAudioTranscription(for: config.providerConfigId)
            || AIConfigService.shared.supportsAudioTranscription(for: config.typeRaw)
        guard supportsTranscription else { return nil }
        guard !Task.isCancelled else { return nil }

        var apiKey = ""
        if let keyId = config.apiKeyKeychainIdentifier {
            apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
        }
        guard !apiKey.isEmpty else { return nil }

        let engine = RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
        do {
            let transcript = try await engine.transcribeFile(audioURL, meetingId: UUID())
            guard !Task.isCancelled else { return nil }
            return transcript.segments.map(\.text).joined(separator: " ")
        } catch { return nil }
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
            self.dictation.audioEngine = engine // Store for proper cleanup
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
        dictation.timer?.invalidate()
        dictation.timer = nil
        dictation.task?.cancel()
        dictation.task = nil
        dictation.audioRecorder?.stop()
        dictation.audioRecorder = nil
        dictation.audioEngine?.stop()
        dictation.audioEngine?.inputNode.removeTap(onBus: 0)
        dictation.audioEngine = nil
        dictation.isDictating = false
        dictation.phase = .idle
    }
}

// MARK: - Chat Input Bar (extracted for focused recomputation scope)

/// Separate view for the chat input bar so that `inputText` changes (every keystroke)
/// only recompute this view, not the entire ChatView including the message list.
struct ChatInputBarView: View {
    @Binding var inputText: String
    var isFocused: FocusState<Bool>.Binding
    let state: ChatViewModel.ChatState
    let compact: Bool
    let dictationPhase: ChatView.DictationPhase
    let dictationElapsed: Double
    let isDictating: Bool
    let modelName: String
    let onSend: () -> Void
    let onCancel: () -> Void
    let onDictate: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Voice dictation button
            Button(action: onDictate) {
                ZStack {
                    if dictationPhase == .recording {
                        Circle()
                            .stroke(.red.opacity(0.3), lineWidth: 2)
                            .frame(width: 44, height: 44)
                            .scaleEffect(1.0 + 0.15 * sin(dictationElapsed * 4))
                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: dictationElapsed)
                    }
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
                    .background(dictationPhase == .recording ? Color.red.opacity(0.15) : Color.clear)
                    .clipShape(Circle())
                }
            }
            .disabled(dictationPhase == .transcribing)

            TextField("Ask anything...", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(.separator)))
                .focused(isFocused)

            // Active model badge — shows which AI model is currently selected
            if !modelName.isEmpty {
                Text(modelName)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }

            if state == .thinking || state == .streaming {
                Button(action: onCancel) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(inputText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.5) : Color.blue)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, compact ? 4 : 8)
        .padding(.bottom, compact ? 0 : 8)
        .background(.bar)
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
        .background(.purple.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.purple.opacity(0.4))
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
                    } else if let attr = try? AttributedString(markdown: message.content) {
                        Text(attr)
                            .font(.body).lineSpacing(4)
                            .foregroundStyle(message.role == .user ? .white : .primary)
                            .textSelection(.enabled)
                    } else {
                        Text(message.content)
                            .font(.body).lineSpacing(4)
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
                .background(message.role == .user ? AnyShapeStyle(effectiveColor) : AnyShapeStyle(.regularMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .leading) {
                    if message.role == .assistant, projectColorHex ?? message.projectColorHex != nil {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
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

/// Reusable collapsible status bar. Shared by AgentStatusBar and PipelineProgressCardView.
/// Tap to expand/collapse detail content.
struct ExpandableStatusBar<Detail: View>: View {
    let label: AnyView
    var showChevron: Bool = true
    @ViewBuilder let detail: () -> Detail

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    label
                    Spacer()
                    if showChevron {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .padding(.horizontal, 16)

            if expanded {
                detail()
                    .padding(.vertical, 3)
            }
        }
    }
}

/// A single compact bar showing agent activity — replaces individual tool call cards.
/// Collapsed by default; tap to expand and see individual tool details.
struct AgentStatusBar: View {
    let state: ChatViewModel.ChatState
    let toolCalls: [ToolCallProgress]

    private var runningCount: Int { toolCalls.filter { $0.status == .running }.count }
    private var completedCount: Int { toolCalls.filter { $0.status == .completed }.count }
    private var failedCount: Int { toolCalls.filter { $0.status == .failed }.count }
    private var totalCount: Int { toolCalls.count }

    var body: some View {
        if totalCount == 0 && state != .thinking { EmptyView() } else {
            ExpandableStatusBar(
                label: AnyView(
                    HStack(spacing: 6) {
                        if state == .thinking && totalCount == 0 {
                            ProgressView().scaleEffect(0.7)
                            Text("Thinking...").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            if runningCount > 0 {
                                ProgressView().scaleEffect(0.7)
                            } else if failedCount > 0 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9)).foregroundStyle(.orange)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9)).foregroundStyle(.green)
                            }
                            Text("\(totalCount) tool\(totalCount == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                            if runningCount > 0 {
                                Text("· \(runningCount) running").font(.caption2).foregroundStyle(.tertiary)
                            }
                            if failedCount > 0 {
                                Text("· \(failedCount) failed").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                ),
                showChevron: totalCount > 0
            ) {
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
            }
        }
    }
}


// MARK: - Streaming message

struct StreamingMessageView: View {
    let text: String
    var projectColorHex: String? = nil
    @State private var cursorVisible = true

    private var cursorColor: Color {
        if let hex = projectColorHex { return Color(hex: hex) }
        return .blue
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(text)
                        .font(.body).lineSpacing(4)
                        .textSelection(.enabled)
                    Text(" ▌")
                        .foregroundColor(cursorColor)
                        .opacity(cursorVisible ? 1 : 0)
                }
            }
            .padding(12)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                cursorVisible = false
            }
        }
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

    private var color: Color {
        switch status.phase {
        case "completed": return .green
        case "error": return .red
        default: return .blue
        }
    }

    var body: some View {
        ExpandableStatusBar(
            label: AnyView(
                HStack(spacing: 6) {
                    if status.phase == "processing" {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: status.phase == "completed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 9)).foregroundStyle(color)
                    }
                    Text("Pipeline: \(status.itemTitle)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let tool = status.currentTool {
                        Text("· \(tool)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            ),
            showChevron: !status.toolLog.isEmpty
        ) {
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

    @State private var cachedBlocks: [ChatBlock]?
    @State private var cachedSmartBlocks: [ChatBlock]?
    @State private var cachedParsedBlocks: [OutputBlock]?

    init(message: ChatMessage, projectColorHex: String? = nil,
         onSendMessage: ((String) -> Void)? = nil,
         onRunCommand: ((String) -> Void)? = nil,
         onChooseOption: ((String) -> Void)? = nil) {
        self.message = message
        self.projectColorHex = projectColorHex
        self.onSendMessage = onSendMessage
        self.onRunCommand = onRunCommand
        self.onChooseOption = onChooseOption
        // Eagerly parse blocks so first render uses final height — avoids two-phase height jump
        self._cachedBlocks = State(initialValue: message.blocks)
        self._cachedSmartBlocks = State(initialValue: SmartBlockParser.parse(message.content, role: message.role))
        self._cachedParsedBlocks = State(initialValue: ContentParser.parse(message.content).0)
    }

    var body: some View {
        Group {
            // 0. Thinking messages — collapsible, distinct visual style
            if message.isThinking == true {
                ThinkingBubble(text: message.content)
            }
            // 1. Structured blocks from ShellInterpreter (touch, ls, etc.)
            else if let blocks = cachedBlocks, !blocks.isEmpty {
                blocksView(blocks)
            }
            // 2. Smart parser: detect patterns in text → interactive blocks
            else if let smart = cachedSmartBlocks, !smart.isEmpty {
                blocksView(smart)
            }
            // 3. Fallback: markdown parser — skip only single .text blocks from assistant
            else if let parsed = cachedParsedBlocks, !parsed.isEmpty {
                let isLoneTextBlock = parsed.count == 1 && message.role == .assistant && { if case .text = parsed[0] { true } else { false } }()
                if !isLoneTextBlock {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(parsed) { block in
                            switch block {
                            case .text(let t): Text(t).font(.body).lineSpacing(4)
                            case .bulletList(let items): ForEach(items, id: \.self) { Text("• \($0)").font(.body) }
                            case .orderedList(let items): ForEach(Array(items.enumerated()), id: \.offset) { i, item in Text("\(i+1). \(item)").font(.body) }
                            case .code(let c): Text(c.code).font(.caption).monospaced()
                            default: Text(String(describing: block)).font(.body)
                            }
                        }
                    }
                    .padding(12).background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ChatMessageBubbleView(message: message, projectColorHex: projectColorHex)
                }
            }
            // 4. Plain text bubble
            else {
                ChatMessageBubbleView(message: message, projectColorHex: projectColorHex)
            }
        }
    }

    private func blocksView(_ blocks: [ChatBlock]) -> some View {
        // Use dashboard grid for 4+ card-type blocks
        let cardBlocks = blocks.filter {
            if case .itemCard = $0 { true } else if case .taskCard = $0 { true } else { false }
        }
        if cardBlocks.count >= 4 {
            return AnyView(dashboardGrid(cardBlocks))
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    ChatBlockView(block: block, projectColorHex: projectColorHex,
                        onSendMessage: onSendMessage, onRunCommand: onRunCommand, onChooseOption: onChooseOption)
                }
            }
            .padding(12).background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
        )
    }

    private func dashboardGrid(_ cards: [ChatBlock]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, block in
                ChatBlockView(block: block, projectColorHex: projectColorHex,
                    onSendMessage: onSendMessage, onRunCommand: onRunCommand, onChooseOption: onChooseOption)
            }
        }
        .padding(8).background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Smart Block Parser

/// Detects markdown patterns in agent text and upgrades them to interactive UI blocks.
enum SmartBlockParser {
    static func parse(_ text: String, role: AIRole) -> [ChatBlock] {
        guard role == .assistant || role == .tool else { return [] }
        var blocks = extractBlocks(text)
        if blocks.count >= 2 || blocks.containsNonText { return injectVFSLinks(blocks, originalText: text) }
        return injectVFSLinks(detectInlineCards(text), originalText: text)
    }

    /// Detect VFS paths in text blocks and convert to clickable fileLink blocks.
    private static func injectVFSLinks(_ blocks: [ChatBlock], originalText: String) -> [ChatBlock] {
        let pattern = #"(/[a-z0-9_-]+(?:/[a-z0-9_.\[\]-]+)*\.?(?:json|md|m4a|jpg|png)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return blocks }

        var result: [ChatBlock] = []
        for block in blocks {
            if case .text(let content) = block {
                let nsText = content as NSString
                let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsText.length))
                guard !matches.isEmpty else { result.append(block); continue }

                var lastEnd = 0
                for match in matches {
                    let range = match.range(at: 1)
                    // Emit any text before this match
                    if range.location > lastEnd {
                        let before = nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
                        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            result.append(.text(before))
                        }
                    }
                    // Emit fileLink for the matched path
                    let path = nsText.substring(with: range)
                    let filename = path.split(separator: "/").last.map(String.init) ?? path
                    result.append(.fileLink(FileLinkData(
                        itemID: path,
                        title: String(filename),
                        itemType: path.hasSuffix(".md") ? "note" : path.hasSuffix(".json") ? "json" : "unknown",
                        snippet: path,
                        projectSlug: nil
                    )))
                    lastEnd = range.location + range.length
                }
                // Emit remaining text after last match
                if lastEnd < nsText.length {
                    let after = nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd))
                    if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append(.text(after))
                    }
                }
            } else {
                result.append(block)
            }
        }
        return result
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
                // Sub-parse section content through ContentParser for structural elements
                let rawContent = content.joined(separator: "\n")
                let parsed = ContentParser.parse(rawContent).0
                if parsed.count > 1 || (parsed.count == 1 && { if case .text = parsed[0] { false } else { true } }()) {
                    // ContentParser found structure — emit as separate blocks
                    blocks.append(.text("**" + section.title + "**"))
                    for block in parsed {
                        blocks.append(convertOutputToChatBlock(block))
                    }
                } else {
                    blocks.append(.text("**" + section.title + "**\n" + rawContent))
                }
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
    /// Converts ContentParser OutputBlock to ChatBlock for unified rendering.
    private static func convertOutputToChatBlock(_ output: OutputBlock) -> ChatBlock {
        switch output {
        case .text(let t): return .text(t)
        case .table(let table): return .table(TableData(title: table.title, headers: table.headers, rows: table.rows))
        case .code(let code): return .code(CodeData(code: code.code, language: code.language, caption: code.caption))
        case .bulletList(let items): return .bulletList(items)
        case .orderedList(let items): return .orderedList(items)
        case .actions(let actions):
            return .taskCard(TaskCardData(
                taskID: UUID().uuidString, title: actions.title ?? "Actions",
                status: "todo", priority: "medium", owner: nil, projectSlug: nil, needsConfirmation: false))
        case .card(let card):
            return .text("**\(card.title)**\n\(card.body)")
        }
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


// Card views (ChatBlockView, ProjectContextCardView, TaskCardView, ItemCardView,
// SearchResultsCardView, AnalysisAccordionView, ChoicePromptView, ConfirmationView)
// Card views extracted to ChatBlockViews.swift — KAN-200