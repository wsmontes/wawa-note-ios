import Foundation

// MARK: - Tool Definition (sent to LLM)

struct AIToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: AIToolParameters
}

struct AIToolParameters: Codable, Sendable {
    let type: String
    let properties: [String: AIToolProperty]
    let required: [String]

    init(properties: [String: AIToolProperty], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct AIToolProperty: Codable, Sendable {
    let type: String
    let description: String
    let `enum`: [String]?

    init(type: String, description: String, enum: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = `enum`
    }
}

// MARK: - Tool Result

struct ToolResult: Sendable {
    let content: String
    let blocks: [ChatBlock]?
    let citations: [ChatCitation]
    let isError: Bool
    let displaySummary: String

    init(content: String, blocks: [ChatBlock]? = nil, citations: [ChatCitation] = [], isError: Bool = false, displaySummary: String? = nil) {
        self.content = content
        self.blocks = blocks
        self.citations = citations
        self.isError = isError
        self.displaySummary = displaySummary ?? String(content.prefix(80))
    }
}

struct ToolCallProgress: Sendable {
    let id: String
    let toolName: String
    let status: ToolCallStatus
    let displaySummary: String?
    let error: String?
}

// MARK: - Tool Protocol

protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: AIToolParameters { get }
    @MainActor func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult
}
