import Foundation

// Related JIRA: KAN-9, KAN-47

// MARK: - Chat Context

enum ChatContext: Equatable, Hashable, Codable {
    case global
    case inbox
    case item(UUID)
    case exploreProjects
    case project(UUID)

    var key: String {
        switch self {
        case .global: return "global"
        case .inbox: return "inbox"
        case .item(let id): return "item:\(id.uuidString)"
        case .exploreProjects: return "explore:projects"
        case .project(let id): return "project:\(id.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case .global: return "General"
        case .inbox: return "Inbox"
        case .item: return "Item"
        case .exploreProjects: return "Projects"
        case .project: return "Project"
        }
    }

    var associatedID: UUID? {
        switch self {
        case .item(let id): return id
        case .project(let id): return id
        default: return nil
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
    /// Custom coding keys exclude the transient _blocksCache
    enum CodingKeys: String, CodingKey {
        case id, conversationId, role, content, createdAt, toolCalls, toolCallId
        case citations, isThinking, projectColorHex, blocksJSON, isInternal
    }

    let id: UUID
    let conversationId: UUID
    var role: AIRole
    var content: String
    var createdAt: Date
    var toolCalls: [PersistedToolCall]?
    var toolCallId: String?
    var citations: [ChatCitation]?
    var isThinking: Bool?
    var projectColorHex: String?
    var blocksJSON: String?
    /// When true, this message is invisible in the chat UI but still sent to the agent.
    /// Used for UI-triggered decisions (ChoicePrompt, swipe actions) that shouldn't
    /// appear as user-typed bubbles.
    var isInternal: Bool

    /// Parsed blocks from blocksJSON. Nil if no structured content (falls back to text parsing).
    /// Decode-once cache: the reference-type wrapper allows mutation from the non-mutating
    /// getter, avoiding repeated JSONDecoder() calls on every SwiftUI body recomputation.
    var blocks: [ChatBlock]? {
        get {
            if let cached = _blocksCache.value { return cached.isEmpty ? nil : cached }
            guard let json = blocksJSON, let data = json.data(using: .utf8) else {
                _blocksCache.value = []
                return nil
            }
            let decoded = (try? JSONDecoder().decode([ChatBlock].self, from: data)) ?? []
            _blocksCache.value = decoded
            return decoded.isEmpty ? nil : decoded
        }
        set {
            _blocksCache.value = newValue ?? []
            if let blocks = newValue, let data = try? JSONEncoder().encode(blocks) {
                blocksJSON = String(data: data, encoding: .utf8)
            } else {
                blocksJSON = nil
            }
        }
    }
    /// Box to allow cache mutation from non-mutating getter (reference type).
    private class BlocksCache { var value: [ChatBlock]? }
    private var _blocksCache = BlocksCache()

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: AIRole,
        content: String,
        createdAt: Date = Date(),
        toolCalls: [PersistedToolCall]? = nil,
        toolCallId: String? = nil,
        citations: [ChatCitation]? = nil,
        isThinking: Bool? = nil,
        projectColorHex: String? = nil,
        blocks: [ChatBlock]? = nil,
        isInternal: Bool = false
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
        self.projectColorHex = projectColorHex
        self.isInternal = isInternal
        self.blocks = blocks
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
    var projectID: UUID?
    var projectColorHex: String?
}

// MARK: - Interactive Chat Blocks

/// Structured content blocks that render as native SwiftUI views in the chat.
/// Emitted by ShellInterpreter tool handlers and persisted in ChatMessage.blocksJSON.
enum ChatBlock: Codable, Sendable {
    case text(String)
    case table(TableData)
    case code(CodeData)
    case bulletList([String])
    case orderedList([String])

    // Interactive cards
    case projectContext(ProjectContextData)
    case taskCard(TaskCardData)
    case itemCard(ItemCardData)
    case searchResults(SearchResultsData)
    case analysisAccordion(AnalysisData)

    // Action prompts
    case choicePrompt(ChoicePromptData)
    case confirmation(ConfirmationData)

    // Document references
    case fileLink(FileLinkData)
    case documentHeader(DocumentHeaderData)

    // Free-text input
    case freeTextInput(FreeTextInputData)

    // Progress tracking
    case progressUpdate(ProgressUpdateData)
}

// MARK: - Block Data Types

struct TableData: Codable, Sendable {
    let title: String?
    let headers: [String]
    let rows: [[String]]
}

struct CodeData: Codable, Sendable {
    let code: String
    let language: String?
    let caption: String?
}

struct ProjectContextData: Codable, Sendable {
    let projectName: String
    let slug: String
    let status: String
    let taskCount: Int
    let itemCount: Int
    let signalCount: Int
    let healthStatus: String?
    let summary: String?
}

struct TaskCardData: Codable, Sendable {
    let taskID: String
    let title: String
    let status: String
    let priority: String
    let owner: String?
    let projectSlug: String?
    let needsConfirmation: Bool  // true = show Confirm/Cancel buttons
}

struct ItemCardData: Codable, Sendable {
    let itemID: String
    let title: String
    let type: String
    let status: String
    let durationSeconds: Double?
    let projectSlug: String?
    let hasTranscript: Bool
    let hasAnalysis: Bool
}

struct SearchResultsData: Codable, Sendable {
    let query: String
    let results: [SearchResultItem]
}

struct SearchResultItem: Codable, Sendable {
    let itemID: String
    let title: String
    let snippet: String
    let type: String
    let projectSlug: String?
}

struct AnalysisData: Codable, Sendable {
    let itemID: String
    let sections: [AnalysisSection]
}

struct AnalysisSection: Codable, Sendable {
    let title: String
    let count: Int
    let items: [String]
}

struct ChoicePromptData: Codable, Sendable {
    let question: String
    let options: [ChoiceOption]
}

struct ChoiceOption: Codable, Sendable {
    let label: String
    let value: String  // sent as user message when tapped
}

struct ConfirmationData: Codable, Sendable {
    let title: String
    let message: String
    let confirmLabel: String
    let cancelLabel: String
    let confirmValue: String
    let cancelValue: String
}

// MARK: - Document Link Data

struct FileLinkData: Codable, Sendable {
    let itemID: String
    let title: String
    let itemType: String
    let snippet: String
    let projectSlug: String?
}

struct DocumentHeaderData: Codable, Sendable {
    let title: String
    let documentType: String
    let summary: String
    let sectionCount: Int
    let itemID: String
}

struct FreeTextInputData: Codable, Sendable {
    let question: String
    let placeholder: String
    let submitLabel: String
}

struct ProgressUpdateData: Codable, Sendable {
    let step: Int
    let total: Int
    let label: String
}
