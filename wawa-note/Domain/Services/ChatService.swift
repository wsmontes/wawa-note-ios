import Foundation
import os

// Related JIRA: KAN-9, KAN-47

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
        return
            all
            .filter { $0.contextKey == contextKey }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    func findOrCreateConversation(for context: ChatContext) throws -> ChatConversation {
        if let existing = try findConversation(for: context.key) {
            return existing
        }
        let defaultTitle: String = {
            switch context {
            case .global: return "General Chat"
            case .inbox: return "Inbox Chat"
            case .item: return "Item Chat"
            case .exploreProjects: return "Projects Chat"
            case .project: return "Project Chat"
            }
        }()
        return try createConversation(title: defaultTitle, contextKey: context.key)
    }

    func fetchConversations() throws -> [ChatConversation] {
        let url = baseURL.appendingPathComponent("index.json")
        let bakURL = url.appendingPathExtension("BAK")

        // Try primary first
        if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if size > 0 {
                if let conversations = try? decodeConversations(from: url) {
                    return conversations
                }
                AppLog.general.warning("ChatService: index.json parse failed (size=\(size)) — trying backup")
            }
        }

        // Fall back to backup
        if FileManager.default.fileExists(atPath: bakURL.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: bakURL.path)[.size] as? Int64) ?? 0
            if size > 0, let conversations = try? decodeConversations(from: bakURL) {
                AppLog.general.info("ChatService: recovered index from backup")
                // Restore primary from backup
                if let bakData = try? Data(contentsOf: bakURL) {
                    try? bakData.write(to: url, options: .atomic)
                }
                return conversations
            }
        }

        // Both failed — attempt rebuild from individual message files
        if let rebuilt = try? rebuildIndexFromMessageFiles() {
            AppLog.general.info("ChatService: rebuilt index.json from \(rebuilt.count) message files")
            try? saveAllConversations(rebuilt)
            return rebuilt
        }

        return []
    }

    private func decodeConversations(from url: URL) throws -> [ChatConversation] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ChatConversation].self, from: data)
    }

    /// Rebuild the conversation index by scanning individual message files.
    /// Extracts title from the first user message, counts messages, and infers
    /// contextKey from the conversation file name or defaults to nil.
    private func rebuildIndexFromMessageFiles() throws -> [ChatConversation] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
        } catch {
            return []
        }

        var conversations: [ChatConversation] = []
        for fileURL in files {
            let idString = fileURL.deletingPathExtension().lastPathComponent
            guard let convId = UUID(uuidString: idString) else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                let messages = try? JSONDecoder().decode([ChatMessage].self, from: data),
                !messages.isEmpty
            else { continue }

            let title: String = {
                if let firstUser = messages.first(where: { $0.role == .user }) {
                    return String(firstUser.content.prefix(60))
                }
                return "Recovered Conversation"
            }()
            let updatedAt = messages.last?.createdAt ?? Date()
            let lastPreview = String(messages.last?.content.prefix(80) ?? "")

            // providerId and model live on ChatConversation, not ChatMessage.
            // During recovery, these aren't available — leave them nil.
            let conversation = ChatConversation(
                id: convId,
                title: title,
                updatedAt: updatedAt,
                providerId: nil,
                model: nil,
                messageCount: messages.count,
                lastMessagePreview: lastPreview,
                contextKey: nil  // Cannot recover contextKey from messages alone
            )
            conversations.append(conversation)
        }
        return conversations
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

    /// Delete a conversation: remove the messages file FIRST, then update the index.
    /// If file removal fails, the conversation stays in the index — no orphans.
    func deleteConversation(id: UUID) throws {
        let msgURL = messagesURL(for: id)

        // Remove messages file first — if this fails, abort
        if FileManager.default.fileExists(atPath: msgURL.path) {
            do {
                try FileManager.default.removeItem(at: msgURL)
            } catch {
                AppLog.general.error("ChatService: cannot delete messages file for conversation \(id) — \(error.localizedDescription)")
                throw error
            }
        }

        // Only after successful file removal, update the index
        var conversations = try fetchConversations()
        conversations.removeAll { $0.id == id }
        try saveAllConversations(conversations)
    }

    // MARK: - Messages

    func messages(for conversationId: UUID) throws -> [ChatMessage] {
        let url = messagesURL(for: conversationId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else { return [] }
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
        try fileStore.createChatDirectory()
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
        let url = baseURL.appendingPathComponent("index.json")
        try fileStore.atomicWriteWithBackup(data: data, url: url)
    }

    private func saveMessages(_ messages: [ChatMessage], conversationId: UUID) throws {
        try fileStore.createChatDirectory()
        let data = try JSONEncoder().encode(messages)
        let url = messagesURL(for: conversationId)
        try fileStore.atomicWriteWithBackup(data: data, url: url)
    }
}
