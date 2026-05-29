import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = ChatViewModel()
    @State private var showConversations = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
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
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    ActiveModelPicker(selectedModel: $viewModel.selectedModel, label: "Model")
                    Button {
                        viewModel.createNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
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
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: viewModel.activeToolCalls.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 80)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
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
        HStack(alignment: .bottom, spacing: 8) {
            // Voice input button
            Button {
                // Future: dictation
            } label: {
                Image(systemName: "mic")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }

            TextField("Ask anything...", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(10)
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
            List {
                ForEach(viewModel.conversations) { conv in
                    Button {
                        viewModel.selectConversation(conv)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conv.title.isEmpty ? "New conversation" : conv.title)
                                .font(.subheadline).fontWeight(.medium).lineLimit(1)
                            HStack {
                                if let preview = conv.lastMessagePreview {
                                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(conv.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { viewModel.deleteConversation(conv) } }
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
