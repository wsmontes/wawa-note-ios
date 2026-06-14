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

    /// Validates arguments against the tool's JSON Schema.
    /// Returns nil if valid, or an error message describing the first violation.
    func validateArguments(_ args: [String: any Sendable]) -> String?
}

extension AgentTool {
    func validateArguments(_ args: [String: any Sendable]) -> String? {
        let schema = parameters

        // Check required fields
        for req in schema.required {
            if args[req] == nil {
                return "Missing required parameter '\(req)' for tool '\(name)'"
            }
        }

        // Check types
        for (key, prop) in schema.properties {
            guard let value = args[key] else { continue }

            let actualType = swiftTypeName(of: value)
            let expectedType = prop.type

            if !typeMatches(actual: actualType, expected: expectedType) {
                return "Parameter '\(key)' for tool '\(name)': expected \(expectedType), got \(actualType)"
            }

            // Check enum constraints
            if let allowed = prop.enum {
                if let strValue = value as? String, !allowed.contains(strValue) {
                    return "Parameter '\(key)' for tool '\(name)': value '\(strValue)' not in allowed values: \(allowed.joined(separator: ", "))"
                }
            }
        }

        return nil  // Valid
    }

    private func swiftTypeName(of value: Any) -> String {
        switch value {
        case is String: return "string"
        case is Int, is Int64: return "integer"
        case is Double, is Float: return "number"
        case is Bool: return "boolean"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return "unknown"
        }
    }

    private func typeMatches(actual: String, expected: String) -> Bool {
        // JSON Schema types: string, integer, number, boolean, array, object
        // Swift types that map to each:
        switch expected {
        case "string": return actual == "string"
        case "integer": return actual == "integer"
        case "number": return actual == "integer" || actual == "number"
        case "boolean": return actual == "boolean"
        case "array": return actual == "array"
        case "object": return actual == "object"
        default: return true  // Unknown type — be permissive
        }
    }
}
