import Foundation
// Related JIRA: KAN-9, KAN-45


final class AgentToolRegistry: @unchecked Sendable {
    private let tools: [String: any AgentTool]

    init(tools: [any AgentTool]) {
        var dict: [String: any AgentTool] = [:]
        for tool in tools {
            dict[tool.name] = tool
        }
        self.tools = dict
    }

    func tool(named name: String) -> (any AgentTool)? {
        tools[name]
    }

    func allTools() -> [any AgentTool] {
        Array(tools.values)
    }

    func allDefinitions() -> [AIToolDefinition] {
        tools.values.map { tool in
            AIToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            )
        }
    }
}
