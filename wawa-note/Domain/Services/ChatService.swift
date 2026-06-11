import Foundation
import os

@MainActor
final class ChatService {
    private let fileStore: FileArtifactStore
    private let baseURL: URL

    /// Serializes read-modify-write in appendMessage/appendMessages.
    /// Prevents TOCTOU races when rapid-fire calls interleave via reentrancy.
    private let appendLock = OSAllocatedUnfairLock()

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
        self.baseURL = fileStore.chatDirectoryURL()
    }

    // MARK: - Conversations

    func createConversation(title: String = "", providerId: UUID? = nil, model: String? = nil, contextKey: String? = nil) throws -> ChatConversation {
        let conversation = ChatConversation(
            title: title,
            providerId: providerId,
            model: model,
            contextKey: contextKey
        )
        try saveConversation(conversation)
        return conversation
    }

    func findConversation(for contextKey: String) throws -> ChatConversation? {
        let all = try fetchConversations()
        return all
            .filter { $0.contextKey == contextKey }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    func findOrCreateConversation(for context: ChatContext) throws -> ChatConversation {
        if let existing = try findConversation(for: context.key) {
            return existing
        }
        let defaultTitle: String = {
            switch context {
            case .global:          return "General Chat"
            case .inbox:           return "Inbox Chat"
            case .item:            return "Item Chat"
            case .exploreProjects: return "Projects Chat"
            case .project:         return "Project Chat"
            }
        }()
        return try createConversation(title: defaultTitle, contextKey: context.key)
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
        appendLock.lock()
        defer { appendLock.unlock() }
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
        appendLock.lock()
        defer { appendLock.unlock() }
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
        try data.write(to: baseURL.appendingPathComponent("index.json"), options: .atomic)
    }

    private func saveMessages(_ messages: [ChatMessage], conversationId: UUID) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(messages)
        try data.write(to: messagesURL(for: conversationId), options: .atomic)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
}
