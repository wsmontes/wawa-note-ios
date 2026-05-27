import SwiftUI
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessageModel] = []
    @Published var inputText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var conversation: ChatConversationModel?
    private let router = ProviderRouter()
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func setConversation(_ conversation: ChatConversationModel) {
        self.conversation = conversation
        messages = conversation.messages?.sorted(by: { $0.createdAt < $1.createdAt }) ?? []
    }

    func newConversation() -> ChatConversationModel {
        let conversation = ChatConversationModel()
        conversation.title = "New Chat"
        modelContext?.insert(conversation)
        try? modelContext?.save()
        self.conversation = conversation
        messages = []
        return conversation
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context = modelContext else { return }

        guard let conversation else {
            errorMessage = "No conversation selected."
            return
        }

        errorMessage = nil
        inputText = ""

        // Save user message
        let userMsg = ChatMessageModel(role: .user, content: text)
        userMsg.conversation = conversation
        context.insert(userMsg)
        messages.append(userMsg)

        // Auto-title from first message
        if conversation.title == "New Chat" {
            conversation.title = String(text.prefix(40))
        }

        guard let config = ActiveProviderManager.shared.getActiveProvider(context: context) else {
            errorMessage = "No AI service connected. Go to Settings > AI Services to connect one."
            return
        }

        let provider: any AIProvider
        do {
            provider = try router.provider(for: config)
        } catch {
            errorMessage = "Could not connect to provider."
            return
        }

        conversation.providerId = config.id
        conversation.model = config.defaultModel
        conversation.updatedAt = Date()

        isLoading = true

        let chatMessages = messages.map { msg in
            AIMessage(role: msg.role, content: [.text(msg.content)])
        }

        let cfg = AIConfigService.shared
        let chatCfg = cfg.featureConfig(for: "chat")
        let model = cfg.modelFor(feature: "chat")
        let systemPrompt = cfg.systemPrompt(for: "chat")

        var allMessages = chatMessages
        if let sys = systemPrompt {
            allMessages.insert(AIMessage(role: .system, content: [.text(sys)]), at: 0)
        }

        let request = AIRequest(
            model: model,
            messages: allMessages,
            temperature: chatCfg?.temperature,
            maxTokens: chatCfg?.maxCompletionTokens ?? chatCfg?.maxTokens
        )

        Task {
            do {
                let response = try await provider.send(request)
                let assistantMsg = ChatMessageModel(role: .assistant, content: response.content)
                assistantMsg.conversation = conversation
                context.insert(assistantMsg)
                messages.append(assistantMsg)

                conversation.updatedAt = Date()
                try? context.save()

            } catch {
                errorMessage = "Failed to get response. Check provider connection."
            }
            isLoading = false
        }
    }
}
