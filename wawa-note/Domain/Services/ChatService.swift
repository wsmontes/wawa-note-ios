import Foundation

@MainActor
final class ChatService {
    private let fileStore: FileArtifactStore
    private let baseURL: URL

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
        self.baseURL = fileStore.chatDirectoryURL()
    }

    // MARK: - Conversations

    func createConversation(title: String = "", providerId: UUID? = nil, model: String? = nil) throws -> ChatConversation {
        let conversation = ChatConversation(
            title: title,
            providerId: providerId,
            model: model
        )
        try saveConversation(conversation)
        return conversation
    }

    func fetchConversations() throws -> [ChatConversation] {
        let url = baseURL.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ChatConversation].self, from: data)
    }

    func updateConversation(_ conversation: ChatConversation) throws {
        var conversations = try fetchConversations()
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.append(conversation)
        }
        try saveAllConversations(conversations)
    }

    func deleteConversation(id: UUID) throws {
        var conversations = try fetchConversations()
        conversations.removeAll { $0.id == id }
        try saveAllConversations(conversations)
        let msgURL = messagesURL(for: id)
        try? FileManager.default.removeItem(at: msgURL)
    }

    // MARK: - Messages

    func messages(for conversationId: UUID) throws -> [ChatMessage] {
        let url = messagesURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ChatMessage].self, from: data)
    }

    func appendMessage(_ message: ChatMessage) throws {
        var messages = try messages(for: message.conversationId)
        messages.append(message)
        try saveMessages(messages, conversationId: message.conversationId)

        var conversation = try fetchConversations().first(where: { $0.id == message.conversationId })
        if var conv = conversation {
            conv.updatedAt = Date()
            conv.messageCount = messages.count
            conv.lastMessagePreview = String(message.content.prefix(80))
            if conv.title.isEmpty && message.role == .user {
                conv.title = String(message.content.prefix(60))
            }
            try updateConversation(conv)
        }
    }

    func appendMessages(_ newMessages: [ChatMessage]) throws {
        guard let conversationId = newMessages.first?.conversationId else { return }
        var messages = try messages(for: conversationId)
        messages.append(contentsOf: newMessages)
        try saveMessages(messages, conversationId: conversationId)
    }

    // MARK: - Private

    private func messagesURL(for conversationId: UUID) -> URL {
        baseURL.appendingPathComponent("\(conversationId.uuidString).json")
    }

    private func saveConversation(_ conversation: ChatConversation) throws {
        try ensureDirectory()
        var conversations = try fetchConversations()
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.append(conversation)
        }
        try saveAllConversations(conversations)
    }

    private func saveAllConversations(_ conversations: [ChatConversation]) throws {
        let data = try JSONEncoder().encode(conversations)
        try data.write(to: baseURL.appendingPathComponent("index.json"))
    }

    private func saveMessages(_ messages: [ChatMessage], conversationId: UUID) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(messages)
        try data.write(to: messagesURL(for: conversationId))
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
}
