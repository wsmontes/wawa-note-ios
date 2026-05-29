import SwiftUI
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var state: ChatState = .idle
    @Published var streamingText: String = ""
    @Published var activeToolCalls: [ToolCallProgress] = []
    @Published var error: String?
    @Published var currentConversation: ChatConversation?
    @Published var conversations: [ChatConversation] = []
    @Published var selectedModel: String = ""

    enum ChatState {
        case idle
        case thinking
        case streaming
        case error
    }

    private let chatService = ChatService()
    private var modelContext: ModelContext?
    private var streamTask: Task<Void, Never>?

    init() {
        loadConversations()
    }

    func setup(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Actions

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .thinking, state != .streaming else { return }
        inputText = ""
        error = nil

        // Ensure conversation exists
        if currentConversation == nil {
            currentConversation = try? chatService.createConversation(title: String(text.prefix(60)))
            loadConversations()
        }

        guard let conv = currentConversation else { return }

        let userMsg = ChatMessage(conversationId: conv.id, role: .user, content: text)
        messages.append(userMsg)
        try? chatService.appendMessage(userMsg)

        guard let ctx = modelContext else { error = "Model context not available."; return }

        // Resolve provider
        guard let provider = try? ProviderRouter.resolveActive(context: ctx) else {
            error = "No AI provider configured. Go to Settings."
            return
        }
        let model = selectedModel.isEmpty ? (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel ?? "gpt-5.5" : selectedModel

        state = .thinking
        streamingText = ""
        activeToolCalls = []
        let conversationId = conv.id

        let registry = AgentToolRegistry(tools: [
            SearchKnowledgeTool(), GetItemTool(), ListItemsTool(),
            GetProjectTool(), GetConnectionsTool(), GetTasksTool(),
            CreateNoteTool(), CreateTaskTool(), SummarizeDayTool()
        ])

        let toolContext = ToolContext(modelContext: ctx)
        let loop = AgentLoop(registry: registry, toolContext: toolContext, model: model)

        streamTask = Task {
            do {
                let stream = loop.runStreaming(userMessage: text, history: messages, provider: provider, model: model)

                var fullContent = ""
                var currentToolId = ""

                for try await event in stream {
                    if Task.isCancelled { break }

                    switch event {
                    case .thinking:
                        state = .thinking
                    case .textDelta(let delta):
                        state = .streaming
                        fullContent += delta
                        streamingText = fullContent
                    case .toolCallStarted(let name, let id, let args):
                        activeToolCalls.append(ToolCallProgress(id: id, toolName: name, status: .running, displaySummary: "Calling \(name)...", error: nil))
                        currentToolId = id
                    case .toolCallCompleted(let name, let id, let summary):
                        if let idx = activeToolCalls.firstIndex(where: { $0.id == id }) {
                            activeToolCalls[idx] = ToolCallProgress(id: id, toolName: name, status: .completed, displaySummary: summary, error: nil)
                        }
                    case .finished(let citations):
                        let assistantMsg = ChatMessage(
                            conversationId: conversationId,
                            role: .assistant,
                            content: fullContent,
                            citations: citations
                        )
                        messages.append(assistantMsg)
                        try? chatService.appendMessage(assistantMsg)
                        streamingText = ""
                        activeToolCalls = []
                        state = .idle
                    case .error(let err):
                        error = err.localizedDescription
                        state = .error
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    state = .error
                }
            }
        }
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        state = .idle
    }

    func createNewConversation() {
        currentConversation = try? chatService.createConversation()
        messages = []
        streamingText = ""
        activeToolCalls = []
        state = .idle
        loadConversations()
    }

    func selectConversation(_ conv: ChatConversation) {
        currentConversation = conv
        messages = (try? chatService.messages(for: conv.id)) ?? []
    }

    func deleteConversation(_ conv: ChatConversation) {
        try? chatService.deleteConversation(id: conv.id)
        if currentConversation?.id == conv.id {
            currentConversation = nil
            messages = []
        }
        loadConversations()
    }

    func loadConversations() {
        conversations = (try? chatService.fetchConversations()) ?? []
    }
}
