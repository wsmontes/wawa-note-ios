import Foundation

enum AIRole: String, Codable {
    case system
    case user
    case assistant
    case tool

    var apiName: String {
        switch self {
        case .system: "system"
        case .user: "user"
        case .assistant: "assistant"
        case .tool: "tool"
        }
    }
}

struct ChatConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var providerId: UUID?
    var model: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerId: UUID? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerId = providerId
        self.model = model
    }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let conversationId: UUID
    var role: AIRole
    var content: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: AIRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}
