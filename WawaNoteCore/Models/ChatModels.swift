import Foundation

// MARK: - Chat Context

public enum ChatContext: Equatable, Hashable, Codable {
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

public enum AIRole: String, Codable {
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

public struct ChatMessage: Identifiable, Codable {public 
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
  public /// When true, this message is invisible in the chat UI but still sent to the agent.
  public /// Used for UI-triggered decisions (ChoicePrompt, swipe actions) that shouldn't
  public /// appear as user-typed bubbles.
  public var isInternal: Bool
public 
  public /// Parsed blocks from blocksJSON. Nil if no structured content (falls back to text parsing).
  var blocks: [ChatBlock]? {
    get {
      guard let json = blocksJSON, let data = json.data(using: .utf8) else { return nil }
      return try? JSONDecoder().decode([ChatBlock].self, from: data)
    public }
    set {
      if let blocks = newValue, let data = try? JSONEncoder().encode(blocks) {
        blocksJSON = String(data: data, encoding: .utf8)
      } else {
        public blocksJSON = nil
      public }
    public }
  public }
public 
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
    public self.id = id
    public self.conversationId = conversationId
    public self.role = role
    public self.content = content
    public self.createdAt = createdAt
    public self.toolCalls = toolCalls
    public self.toolCallId = toolCallId
    public self.citations = citations
    public self.isThinking = isThinking
    public self.projectColorHex = projectColorHex
    public self.isInternal = isInternal
    public self.blocks = blocks
  public }
public }

// MARK: - Tool call persistence

public struct PersistedToolCall: Codable {
  public let id: String
  public let name: String
  public let arguments: String
  public var resultPreview: String?
  public var statusRaw: String

  var status: ToolCallStatus {
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

public enum ToolCallStatus: String, Codable {
  case pending
  case running
  case completed
  case failed
}

// MARK: - Citation

public struct ChatCitation: Codable {
  public let itemId: UUID
  public let title: String
  public let snippet: String
  public let itemType: KnowledgeItemType
  public var projectID: UUID?
  public var projectColorHex: String?
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
  let title: String?
  let headers: [String]
  let rows: [[String]]
}

public struct CodeData: Codable, Sendable {
  let code: String
  let language: String?
  let caption: String?
}

public struct ProjectContextData: Codable, Sendable {
  let projectName: String
  let slug: String
  let status: String
  let taskCount: Int
  let itemCount: Int
  let signalCount: Int
  let healthStatus: String?
  let summary: String?
}

public struct TaskCardData: Codable, Sendable {
  let taskID: String
  let title: String
  let status: String
  let priority: String
  let owner: String?
  let projectSlug: String?
  let needsConfirmation: Bool  // true = show Confirm/Cancel buttons
}

public struct ItemCardData: Codable, Sendable {
  let itemID: String
  let title: String
  let type: String
  let status: String
  let durationSeconds: Double?
  let projectSlug: String?
  let hasTranscript: Bool
  let hasAnalysis: Bool
}

public struct SearchResultsData: Codable, Sendable {
  let query: String
  let results: [SearchResultItem]
}

public struct SearchResultItem: Codable, Sendable {
  let itemID: String
  let title: String
  let snippet: String
  let type: String
  let projectSlug: String?
}

public struct AnalysisData: Codable, Sendable {
  let itemID: String
  let sections: [AnalysisSection]
}

public struct AnalysisSection: Codable, Sendable {
  let title: String
  let count: Int
  let items: [String]
}

public struct ChoicePromptData: Codable, Sendable {
  let question: String
  let options: [ChoiceOption]
}

public struct ChoiceOption: Codable, Sendable {
  let label: String
  let value: String  // sent as user message when tapped
}

public struct ConfirmationData: Codable, Sendable {
  let title: String
  let message: String
  let confirmLabel: String
  let cancelLabel: String
  let confirmValue: String
  let cancelValue: String
}

// MARK: - Document Link Data

public struct FileLinkData: Codable, Sendable {
  let itemID: String
  let title: String
  let itemType: String
  let snippet: String
  let projectSlug: String?
}

public struct DocumentHeaderData: Codable, Sendable {
  let title: String
  let documentType: String
  let summary: String
  let sectionCount: Int
  let itemID: String
}

public struct FreeTextInputData: Codable, Sendable {
  let question: String
  let placeholder: String
  let submitLabel: String
}

public struct ProgressUpdateData: Codable, Sendable {
  let step: Int
  let total: Int
  let label: String
}
