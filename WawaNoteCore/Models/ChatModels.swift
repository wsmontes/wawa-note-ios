import Foundation

// MARK: - Chat Context

public enum ChatContext: Equatable, Hashable, Codable {
  case global
  case inbox
  case item(UUID)
  case exploreProjects
  case project(UUID)

  public var key: String {
    switch self {
    case .global: return "global"
    case .inbox: return "inbox"
    case .item(let id): return "item:\(id.uuidString)"
    case .exploreProjects: return "explore:projects"
    case .project(let id): return "project:\(id.uuidString)"
    }
  }

  public var displayName: String {
    switch self {
    case .global: return "General"
    case .inbox: return "Inbox"
    case .item: return "Item"
    case .exploreProjects: return "Projects"
    case .project: return "Project"
    }
  }

  public var associatedID: UUID? {
    switch self {
    case .item(let id): return id
    case .project(let id): return id
    default: return nil
    }
  }

  public static func from(key: String) -> ChatContext? {
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

public enum AIRole: String, Codable, Sendable {
  case system
  case user
  case assistant
  case tool

  public var apiName: String {
    switch self {
    case .system: "system"
    case .user: "user"
    case .assistant: "assistant"
    case .tool: "tool"
    }
  }
}

// MARK: - Conversation

public struct ChatConversation: Identifiable, Codable {
  public let id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var providerId: UUID?
  public var model: String?
  public var messageCount: Int
  public var pinnedAt: Date?
  public var lastMessagePreview: String?
  public var contextKey: String?

  public init(
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

public struct ChatMessage: Identifiable, Codable {
  public let id: UUID
  public let conversationId: UUID
  public var role: AIRole
  public var content: String
  public var createdAt: Date
  public var toolCalls: [PersistedToolCall]?
  public var toolCallId: String?
  public var citations: [ChatCitation]?
  public var isThinking: Bool?
  public var projectColorHex: String?
  public var blocksJSON: String?
  /// When true, this message is invisible in the chat UI but still sent to the agent.
  /// Used for UI-triggered decisions (ChoicePrompt, swipe actions) that shouldn't
  /// appear as user-typed bubbles.
  public var isInternal: Bool

  /// Parsed blocks from blocksJSON. Nil if no structured content (falls back to text parsing).
  public var blocks: [ChatBlock]? {
    get {
      guard let json = blocksJSON, let data = json.data(using: .utf8) else { return nil }
      return try? JSONDecoder().decode([ChatBlock].self, from: data)
    }
    set {
      if let blocks = newValue, let data = try? JSONEncoder().encode(blocks) {
        blocksJSON = String(data: data, encoding: .utf8)
      } else {
        blocksJSON = nil
      }
    }
  }

  public init(
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

public struct PersistedToolCall: Codable {
  public let id: String
  public let name: String
  public let arguments: String
  public var resultPreview: String?
  public var statusRaw: String

  public var status: ToolCallStatus {
    get { ToolCallStatus(rawValue: statusRaw) ?? .pending }
    set { statusRaw = newValue.rawValue }
  }

  public init(
    id: String, name: String, arguments: String, resultPreview: String? = nil,
    status: ToolCallStatus = .pending
  ) {
    self.id = id
    self.name = name
    self.arguments = arguments
    self.resultPreview = resultPreview
    self.statusRaw = status.rawValue
  }
}

public enum ToolCallStatus: String, Codable, Sendable {
  case pending
  case running
  case completed
  case failed
}

// MARK: - Citation

public struct ChatCitation: Codable, Sendable {
  public let itemId: UUID
  public let title: String
  public let snippet: String
  public let itemType: KnowledgeItemType
  public var projectID: UUID?
  public var projectColorHex: String?
  public init(itemId: UUID, title: String = "", snippet: String = "", itemType: KnowledgeItemType, projectID: UUID? = nil, projectColorHex: String? = nil) {
    self.itemId = itemId; self.title = title; self.snippet = snippet; self.itemType = itemType; self.projectID = projectID; self.projectColorHex = projectColorHex
  }
}

// MARK: - Interactive Chat Blocks

/// Structured content blocks that render as native SwiftUI views in the chat.
/// Emitted by ShellInterpreter tool handlers and persisted in ChatMessage.blocksJSON.
public enum ChatBlock: Codable, Sendable {
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

public struct TableData: Codable, Sendable {
  public let title: String?
  public let headers: [String]
  public let rows: [[String]]
  public init(title: String? = nil, headers: [String], rows: [[String]]) {
    self.title = title; self.headers = headers; self.rows = rows
  }
}

public struct CodeData: Codable, Sendable {
  public let code: String
  public let language: String?
  public let caption: String?
  public init(code: String = "", language: String? = nil, caption: String? = nil) {
    self.code = code; self.language = language; self.caption = caption
  }
}

public struct ProjectContextData: Codable, Sendable {
  public let projectName: String
  public let slug: String
  public let status: String
  public let taskCount: Int
  public let itemCount: Int
  public let signalCount: Int
  public let healthStatus: String?
  public let summary: String?
  public init(projectName: String, slug: String, status: String, taskCount: Int, itemCount: Int, signalCount: Int, healthStatus: String? = nil, summary: String? = nil) { self.projectName = projectName; self.slug = slug; self.status = status; self.taskCount = taskCount; self.itemCount = itemCount; self.signalCount = signalCount; self.healthStatus = healthStatus; self.summary = summary }
}

public struct TaskCardData: Codable, Sendable {
  public let taskID: String
  public let title: String
  public let status: String
  public let priority: String
  public let owner: String?
  public let projectSlug: String?
  public let needsConfirmation: Bool  // true = show Confirm/Cancel buttons
  public init(taskID: String, title: String, status: String, priority: String, ownerName: String? = nil, dueDate: String? = nil, projectID: String? = nil) { self.taskID = taskID; self.title = title; self.status = status; self.priority = priority; self.ownerName = ownerName; self.dueDate = dueDate; self.projectID = projectID }
}

public struct ItemCardData: Codable, Sendable {
  public let itemID: String
  public let title: String
  public let type: String
  public let status: String
  public let durationSeconds: Double?
  public let projectSlug: String?
  public let hasTranscript: Bool
  public let hasAnalysis: Bool
  public init(itemID: String, title: String, type: String, status: String? = nil, durationSeconds: Double? = nil, projectSlug: String? = nil, hasTranscript: Bool = false, hasAnalysis: Bool = false) { self.itemID = itemID; self.title = title; self.type = type; self.status = status; self.durationSeconds = durationSeconds; self.projectSlug = projectSlug; self.hasTranscript = hasTranscript; self.hasAnalysis = hasAnalysis }
}

public struct SearchResultsData: Codable, Sendable {
  public let query: String
  public let results: [SearchResultItem]
  public init(query: String = "", results: [SearchResultItem]) {
    self.query = query; self.results = results
  }
}

public struct SearchResultItem: Codable, Sendable {
  public let itemID: String
  public let title: String
  public let snippet: String
  public let type: String
  public let projectSlug: String?
  public init(itemID: String = "", title: String = "", snippet: String = "", type: String = "", projectSlug: String? = nil) {
    self.itemID = itemID; self.title = title; self.snippet = snippet; self.type = type; self.projectSlug = projectSlug
  }
}

public struct AnalysisData: Codable, Sendable {
  public let itemID: String
  public let sections: [AnalysisSection]
  public init(itemID: String = "", sections: [AnalysisSection]) {
    self.itemID = itemID; self.sections = sections
  }
}

public struct AnalysisSection: Codable, Sendable {
  public let title: String
  public let count: Int
  public let items: [String]
  public init(title: String = "", count: Int = 0, items: [String]) {
    self.title = title; self.count = count; self.items = items
  }
}

public struct ChoicePromptData: Codable, Sendable {
  public let question: String
  public let options: [ChoiceOption]
  public init(question: String, options: [ChoiceOption]) { self.question = question; self.options = options }
}

public struct ChoiceOption: Codable, Sendable {
  public let label: String
  public let value: String  // sent as user message when tapped
  public init(label: String, value: String) { self.label = label; self.value = value }
}

public struct ConfirmationData: Codable, Sendable {
  public let title: String
  public let message: String
  public let confirmLabel: String
  public let cancelLabel: String
  public let confirmValue: String
  public let cancelValue: String
  public init(message: String, confirmLabel: String = "Confirm", cancelLabel: String = "Cancel", isDestructive: Bool = false) { self.message = message; self.confirmLabel = confirmLabel; self.cancelLabel = cancelLabel; self.isDestructive = isDestructive }
}

// MARK: - Document Link Data

public struct FileLinkData: Codable, Sendable {
  public let itemID: String
  public let title: String
  public let itemType: String
  public let snippet: String
  public let projectSlug: String?
  public init(itemID: String, title: String, fileType: String? = nil, size: String? = nil, path: String? = nil) { self.itemID = itemID; self.title = title; self.fileType = fileType; self.size = size; self.path = path }
}

public struct DocumentHeaderData: Codable, Sendable {
  public let title: String
  public let documentType: String
  public let summary: String
  public let sectionCount: Int
  public let itemID: String
  public init(title: String, documentType: String, date: String? = nil, source: String? = nil, itemID: String? = nil) { self.title = title; self.documentType = documentType; self.date = date; self.source = source; self.itemID = itemID }
}

public struct FreeTextInputData: Codable, Sendable {
  public let question: String
  public let placeholder: String
  public let submitLabel: String
  public init(question: String, placeholder: String? = nil, submitLabel: String = "Submit") { self.question = question; self.placeholder = placeholder; self.submitLabel = submitLabel }
}

public struct ProgressUpdateData: Codable, Sendable {
  public let step: Int
  public let total: Int
  public let label: String
  public init(step: Int, total: Int, label: String = "") { self.step = step; self.total = total; self.label = label }
}
