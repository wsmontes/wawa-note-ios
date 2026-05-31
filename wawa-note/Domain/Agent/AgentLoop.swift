import Foundation
import OSLog

// MARK: - Stream events

enum AgentStreamEvent {
    case thinking
    case textDelta(String)
    case toolCallStarted(name: String, id: String, arguments: String)
    case toolCallCompleted(name: String, id: String, summary: String)
    case finished(citations: [ChatCitation])
    case error(Error)
}

// MARK: - Agent Loop

final class AgentLoop: @unchecked Sendable {
    let maxIterations: Int
    let registry: AgentToolRegistry
    let toolContext: ToolContext
    let contextManager: ContextWindowManager

    init(
        registry: AgentToolRegistry,
        toolContext: ToolContext,
        maxIterations: Int = 8,
        model: String = "gpt-5.5"
    ) {
        self.registry = registry
        self.toolContext = toolContext
        self.maxIterations = maxIterations
        let config = AIConfigService.shared
        let contextLimit = config.contextWindowTokens(for: model)
        self.contextManager = ContextWindowManager(modelContextLimit: contextLimit)
    }

    func runStreaming(
        userMessage: String,
        history: [ChatMessage],
        provider: any AIProvider,
        model: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runLoop(
                        userMessage: userMessage,
                        history: history,
                        provider: provider,
                        model: model,
                        continuation: continuation
                    )
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    private func runLoop(
        userMessage: String,
        history: [ChatMessage],
        provider: any AIProvider,
        model: String,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        let systemPrompt = buildSystemPrompt()
        let tools = registry.allDefinitions()

        var messages: [ChatMessage] = history
        messages.append(ChatMessage(conversationId: UUID(), role: .user, content: userMessage))

        var allCitations: [ChatCitation] = []
        let maxIter = maxIterations

        for iteration in 0..<maxIter {
            continuation.yield(.thinking)

            let (contextMessages, wasTruncated, truncatedCount) = contextManager.prepareMessages(
                history: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                maxTokensBudget: contextManager.modelContextLimit * 80 / 100
            )

            // Warn the model when context was lost due to token limits
            var adjustedMessages = contextMessages
            if wasTruncated {
                let warning = ChatMessage(
                    conversationId: UUID(),
                    role: .system,
                    content: "[SYSTEM NOTE: \(truncatedCount) older messages were truncated due to token limits. The conversation history is incomplete. If the user asks about earlier context, let them know you no longer have access to those messages.]"
                )
                adjustedMessages.insert(warning, at: 0)
            }

            let request = buildRequest(
                systemPrompt: systemPrompt,
                contextMessages: adjustedMessages,
                tools: tools,
                model: model
            )

            let stream = provider.sendStreaming(request)
            var fullContent = ""
            var pendingToolCalls: [(id: String, name: String, arguments: String)] = []
            var currentTCID = ""
            var currentTCName: String?
            var currentTCArgs = ""

            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    fullContent += delta
                    continuation.yield(.textDelta(delta))

                case .toolCallDelta(let id, let name, let args):
                    // When ID changes, commit the previous tool call
                    if !currentTCID.isEmpty && id != currentTCID, let n = currentTCName {
                        pendingToolCalls.append((id: currentTCID, name: n, arguments: currentTCArgs))
                        currentTCArgs = ""
                    }
                    currentTCID = id
                    if let n = name { currentTCName = n }
                    if let a = args { currentTCArgs += a }

                case .finished:
                    break
                }
            }
            // Commit last pending tool call
            if !currentTCID.isEmpty, let n = currentTCName {
                pendingToolCalls.append((id: currentTCID, name: n, arguments: currentTCArgs))
            }

            if !pendingToolCalls.isEmpty {
                // Store all tool calls in one assistant message
                let persistedCalls: [PersistedToolCall] = pendingToolCalls.map { tc in
                    PersistedToolCall(id: tc.id, name: tc.name, arguments: tc.arguments, status: .running)
                }

                let assistantMsg = ChatMessage(
                    conversationId: UUID(),
                    role: .assistant,
                    content: fullContent,
                    toolCalls: persistedCalls
                )
                messages.append(assistantMsg)

                // Execute ALL tool calls — OpenAI requires a tool message for EVERY tool call
                for tc in pendingToolCalls {
                    let toolCallID = tc.id
                    let toolCallName = tc.name
                    let toolCallArgs = tc.arguments

                    continuation.yield(.toolCallStarted(name: toolCallName, id: toolCallID, arguments: toolCallArgs))

                    guard let tool = registry.tool(named: toolCallName) else {
                        let availableTools = registry.allDefinitions().map(\.name).joined(separator: ", ")
                        let errorMsg = ChatMessage(
                            conversationId: UUID(), role: .tool,
                            content: "TOOL ERROR: '\(toolCallName)' is not a valid tool. Available tools: \(availableTools).",
                            toolCallId: toolCallID
                        )
                        messages.append(errorMsg)
                        continuation.yield(.toolCallCompleted(name: toolCallName, id: toolCallID, summary: "Error: unknown tool"))
                        continue
                    }

                    let args = parseArguments(toolCallArgs, toolName: toolCallName)
                    let result: ToolResult
                    do {
                        result = try await tool.execute(args, context: toolContext)
                    } catch {
                        let errorMsg = ChatMessage(
                            conversationId: UUID(), role: .tool,
                            content: "TOOL ERROR: \(toolCallName) exception: \(error.localizedDescription)",
                            toolCallId: toolCallID
                        )
                        messages.append(errorMsg)
                        continuation.yield(.toolCallCompleted(name: toolCallName, id: toolCallID, summary: "Error"))
                        continue
                    }

                    allCitations.append(contentsOf: result.citations)
                    continuation.yield(.toolCallCompleted(name: toolCallName, id: toolCallID, summary: result.displaySummary))

                    let prefix = result.isError ? "TOOL ERROR: " : ""
                    let toolMsg = ChatMessage(
                        conversationId: UUID(), role: .tool,
                        content: prefix + result.content,
                        toolCallId: toolCallID
                    )
                    messages.append(toolMsg)
                }
            } else {
                let assistantMsg = ChatMessage(
                    conversationId: UUID(),
                    role: .assistant,
                    content: fullContent,
                    citations: allCitations
                )
                messages.append(assistantMsg)
                continuation.yield(.finished(citations: allCitations))
                continuation.finish()
                return
            }
        }

        continuation.yield(.finished(citations: allCitations))
        continuation.finish()
    }

    // MARK: - Helpers

    private func buildSystemPrompt() -> String {
        let tools = registry.allDefinitions()
        let toolList = tools.map { tool in
            let params = tool.parameters.properties.keys.sorted().joined(separator: ", ")
            return "- `\(tool.name)`\(params.isEmpty ? "" : "(\(params))"): \(tool.description)"
        }.joined(separator: "\n")

        return """
        You are Wawa, an AI assistant with access to the user's personal knowledge workspace.

        AVAILABLE TOOLS:
        \(toolList)

        HOW TO USE TOOLS:
        - Call tools using the exact function name. Arguments must be valid JSON.
        - Use search_knowledge to find information by keywords. Always search before answering factual questions.
        - Use get_item to fetch the full content of a specific item by its UUID.
        - Use list_items to browse by type, date range, or filter.
        - Use get_project to see a project's tasks and connected items.
        - Use get_connections to explore how items relate to each other.
        - Use create_note and create_task ONLY when the user explicitly asks you to create something. Confirm first.
        - If a tool returns an error, read the error message and retry with corrected arguments.
        - If you get a tool call error related to parameters, fix the parameter format and try again.

        RULES:
        1. NEVER guess or make up facts. Always search or fetch before answering.
        2. Cite items by their title and ID when referencing them.
        3. If search returns no results, tell the user honestly and suggest alternatives.
        4. Be concise. Answer the question directly, then offer to explore further.
        5. For date-based queries ("last week", "yesterday"), compute the correct ISO 8601 dates using today's date: \(Date().formatted(date: .complete, time: .omitted)).
        6. Item IDs are UUIDs. Use the exact IDs returned by search or list tools.
        7. If you need clarification, ask — don't assume.
        """
    }

    private func buildRequest(
        systemPrompt: String,
        contextMessages: [ChatMessage],
        tools: [AIToolDefinition],
        model: String
    ) -> AIRequest {
        var aiMessages: [AIMessage] = [
            AIMessage(role: .system, content: [.text(systemPrompt)])
        ]

        for msg in contextMessages {
            let msgToolCalls: [AIToolCall]? = msg.toolCalls?.compactMap { tc in
                AIToolCall(id: tc.id, name: tc.name, arguments: tc.arguments)
            }
            let msg = AIMessage(
                role: msg.role,
                content: [.text(msg.content)],
                toolCalls: msgToolCalls,
                toolCallId: msg.toolCallId
            )
            aiMessages.append(msg)
        }

        let params = AIConfigService.shared.requestParams(for: "agent", model: model)

        let hasToolSupport = !tools.isEmpty

        return AIRequest(
            model: model,
            messages: aiMessages,
            temperature: params.temperature,
            maxTokens: params.maxTokens,
            tools: hasToolSupport ? tools : nil,
            toolChoice: hasToolSupport ? "auto" : nil
        )
    }

    private func parseArguments(_ json: String, toolName: String) -> [String: any Sendable] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            AppLog.provider.error("AgentLoop: parseArguments failed — empty or invalid UTF8 for tool '\(toolName)'. Raw: '\(json.prefix(200))'")
            return [:]
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLog.provider.error("AgentLoop: parseArguments failed — not a JSON object for tool '\(toolName)'. Raw: '\(trimmed.prefix(200))'")
            return [:]
        }
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            if let strValue = value as? String { result[key] = strValue }
            else if let intValue = value as? Int { result[key] = intValue }
            else if let doubleValue = value as? Double { result[key] = doubleValue }
            else if let boolValue = value as? Bool { result[key] = boolValue }
            else if let arrayValue = value as? [String] { result[key] = arrayValue }
        }
        AppLog.provider.info("AgentLoop: parsed \(result.count) args for '\(toolName)': keys=\(result.keys.sorted().joined(separator: ","))")
        return result
    }
}
