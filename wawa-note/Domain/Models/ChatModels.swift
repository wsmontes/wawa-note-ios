import Foundation

// MARK: - Chat Context

enum ChatContext: Equatable, Hashable, Codable {
    case global
    case inbox
    case item(UUID)
    case exploreProjects
    case project(UUID)

    var key: String {
        switch self {
        case .global:           return "global"
        case .inbox:            return "inbox"
        case .item(let id):     return "item:\(id.uuidString)"
        case .exploreProjects:  return "explore:projects"
        case .project(let id):  return "project:\(id.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case .global:           return "General"
        case .inbox:            return "Inbox"
        case .item:             return "Item"
        case .exploreProjects:  return "Projects"
        case .project:          return "Project"
        }
    }

    var associatedID: UUID? {
        switch self {
        case .item(let id):     return id
        case .project(let id):  return id
        default:                return nil
        }
    }

    static func from(key: String) -> ChatContext? {
        switch key {
        case "global": return .global
        case "inbox": return .inbox
        case "explore:projects": return .exploreProjects
        default:
            if key.hasPrefix("item:"), let uuid = UUID(uuidString: String(key.dropFirst(5))) {
                return .item(uuid)
            }
            if key.hasPrefix("project:"), let uuid = UUID(uuidString: String(key.dropFirst(8))) {
                return .project(uuid)
            }
            return nil
        }
    }
}

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

// MARK: - Conversation

struct ChatConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var providerId: UUID?
    var model: String?
    var messageCount: Int
    var pinnedAt: Date?
    var lastMessagePreview: String?
    var contextKey: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerId: UUID? = nil,
        model: String? = nil,
        messageCount: Int = 0,
        pinnedAt: Date? = nil,
        lastMessagePreview: String? = nil,
        contextKey: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerId = providerId
        self.model = model
        self.messageCount = messageCount
        self.pinnedAt = pinnedAt
        self.lastMessagePreview = lastMessagePreview
        self.contextKey = contextKey
    }
}

// MARK: - Message

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let conversationId: UUID
    var role: AIRole
    var content: String
    var createdAt: Date
    var toolCalls: [PersistedToolCall]?
    var toolCallId: String?
    var citations: [ChatCitation]?
    var isThinking: Bool?

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: AIRole,
        content: String,
        createdAt: Date = Date(),
        toolCalls: [PersistedToolCall]? = nil,
        toolCallId: String? = nil,
        citations: [ChatCitation]? = nil,
        isThinking: Bool? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.citations = citations
        self.isThinking = isThinking
    }
}

// MARK: - Tool call persistence

struct PersistedToolCall: Codable {
    let id: String
    let name: String
    let arguments: String
    var resultPreview: String?
    var statusRaw: String

    var status: ToolCallStatus {
        get { ToolCallStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(id: String, name: String, arguments: String, resultPreview: String? = nil, status: ToolCallStatus = .pending) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.resultPreview = resultPreview
        self.statusRaw = status.rawValue
    }
}

enum ToolCallStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
}

// MARK: - Citation

struct ChatCitation: Codable {
    let itemId: UUID
    let title: String
    let snippet: String
    let itemType: KnowledgeItemType
}
