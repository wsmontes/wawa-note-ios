import Foundation
import OSLog

// MARK: - Agent mode

enum AgentMode: String, Sendable {
    case auto
    case deep
    case fast
}

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
    let mode: AgentMode
    let executorModel: String
    let advisorModel: String

    init(
        registry: AgentToolRegistry,
        toolContext: ToolContext,
        maxIterations: Int = 12,
        mode: AgentMode = .auto,
        executorModel: String = "gpt-5-nano",
        advisorModel: String = "gpt-5.5"
    ) {
        self.registry = registry
        self.toolContext = toolContext
        self.maxIterations = maxIterations
        self.mode = mode
        self.executorModel = executorModel
        self.advisorModel = advisorModel
        let config = AIConfigService.shared
        let primaryModel = mode == .deep ? advisorModel : executorModel
        let contextLimit = config.contextWindowTokens(for: primaryModel)
        self.contextManager = ContextWindowManager(modelContextLimit: contextLimit)
    }

    // MARK: - Interactive mode (user chat)

    func runStreaming(
        userMessage: String,
        history: [ChatMessage],
        provider: any AIProvider
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runLoop(
                        initialMessage: userMessage,
                        initialRole: .user,
                        systemPrompt: self.buildSystemPrompt(),
                        tools: self.registry.allDefinitions(),
                        history: history,
                        provider: provider,
                        continuation: continuation
                    )
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Autonomous mode (pipeline / sub-agent)

    /// Runs the agent loop autonomously — no user interaction.
    /// The `task` is the initial instruction (e.g. "Process item X through the content pipeline").
    /// `systemPrompt` is the pipeline template (defines the agent's behavior and rules).
    /// `tools` restricts which tools are available (pipeline may use fewer tools than chat).
    func runAutonomous(
        task: String,
        systemPrompt: String,
        tools: [any AgentTool],
        history: [ChatMessage] = [],
        provider: any AIProvider,
        maxIterations overrideIterations: Int? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let toolDefs = tools.map { tool in
                        AIToolDefinition(name: tool.name, description: tool.description, parameters: tool.parameters)
                    }
                    try await self.runLoop(
                        initialMessage: task,
                        initialRole: .system,
                        systemPrompt: systemPrompt,
                        tools: toolDefs,
                        history: history,
                        provider: provider,
                        continuation: continuation,
                        maxIterations: overrideIterations ?? self.maxIterations,
                        toolRegistry: AgentToolRegistry(tools: tools)
                    )
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Core loop

    private func runLoop(
        initialMessage: String,
        initialRole: AIRole,
        systemPrompt: String,
        tools: [AIToolDefinition],
        history: [ChatMessage],
        provider: any AIProvider,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        maxIterations: Int? = nil,
        toolRegistry customRegistry: AgentToolRegistry? = nil
    ) async throws {
        let effectiveRegistry = customRegistry ?? registry
        let iterations = maxIterations ?? self.maxIterations
        var messages = history
        messages.append(ChatMessage(conversationId: UUID(), role: initialRole, content: initialMessage))
        var allCitations: [ChatCitation] = []

        for iteration in 0..<iterations {
            continuation.yield(.thinking)
            let model = resolveModel(for: iteration)

            let (contextMessages, wasTruncated, truncatedCount) = contextManager.prepareMessages(
                history: messages, systemPrompt: systemPrompt, tools: tools,
                maxTokensBudget: contextManager.modelContextLimit * 80 / 100
            )

            var adjusted = contextMessages
            if wasTruncated {
                adjusted.insert(ChatMessage(conversationId: UUID(), role: .system,
                    content: "[SYSTEM NOTE: \(truncatedCount) older messages were truncated due to token limits.]"
                ), at: 0)
            }

            let request = buildRequest(systemPrompt: systemPrompt, contextMessages: adjusted, tools: tools, model: model)
            let stream = provider.sendStreaming(request)
            var fullContent = ""
            var pendingToolCalls: [(id: String, name: String, arguments: String)] = []
            var currentTCID = ""
            var currentTCName: String?
            var currentTCArgs = ""

            for try await event in stream {
                switch event {
                case .textDelta(let d): fullContent += d; continuation.yield(.textDelta(d))
                case .toolCallDelta(let id, let name, let args):
                    if !currentTCID.isEmpty && id != currentTCID, let n = currentTCName {
                        pendingToolCalls.append((id: currentTCID, name: n, arguments: currentTCArgs)); currentTCArgs = ""
                    }
                    currentTCID = id
                    if let n = name { currentTCName = n }
                    if let a = args { currentTCArgs += a }
                case .finished: break
                }
            }
            if !currentTCID.isEmpty, let n = currentTCName {
                pendingToolCalls.append((id: currentTCID, name: n, arguments: currentTCArgs))
            }

            if !pendingToolCalls.isEmpty {
                messages.append(ChatMessage(conversationId: UUID(), role: .assistant, content: fullContent,
                    toolCalls: pendingToolCalls.map { PersistedToolCall(id: $0.id, name: $0.name, arguments: $0.arguments, status: .running) }))

                for tc in pendingToolCalls {
                    continuation.yield(.toolCallStarted(name: tc.name, id: tc.id, arguments: tc.arguments))

                    guard let tool = effectiveRegistry.tool(named: tc.name) else {
                        messages.append(ChatMessage(conversationId: UUID(), role: .tool,
                            content: "TOOL ERROR: unknown tool '\(tc.name)'", toolCallId: tc.id))
                        continuation.yield(.toolCallCompleted(name: tc.name, id: tc.id, summary: "Error"))
                        continue
                    }

                    let args = parseArguments(tc.arguments, toolName: tc.name)
                    let result: ToolResult
                    do { result = try await tool.execute(args, context: toolContext) }
                    catch {
                        messages.append(ChatMessage(conversationId: UUID(), role: .tool,
                            content: "TOOL ERROR: \(tc.name): \(error.localizedDescription)", toolCallId: tc.id))
                        continuation.yield(.toolCallCompleted(name: tc.name, id: tc.id, summary: "Error"))
                        continue
                    }

                    allCitations.append(contentsOf: result.citations)
                    continuation.yield(.toolCallCompleted(name: tc.name, id: tc.id, summary: result.displaySummary))
                    messages.append(ChatMessage(conversationId: UUID(), role: .tool,
                        content: (result.isError ? "TOOL ERROR: " : "") + result.content, toolCallId: tc.id))
                }
            } else {
                messages.append(ChatMessage(conversationId: UUID(), role: .assistant, content: fullContent, citations: allCitations))
                continuation.yield(.finished(citations: allCitations))
                continuation.finish()
                return
            }
        }
        continuation.yield(.finished(citations: allCitations))
        continuation.finish()
    }

    // MARK: - Model resolution

    /// Dynamic model routing based on mode and iteration phase.
    /// Early iterations (tool calls, extraction) use executor model.
    /// Later iterations (synthesis, analysis) use advisor model.
    /// In .deep mode, advisor is used for all iterations.
    /// In .fast mode, executor is used for all iterations.
    /// In .auto mode, executor is used for iterations 0-2, advisor for 3+.
    private func resolveModel(for iteration: Int) -> String {
        switch mode {
        case .deep: return advisorModel
        case .fast: return executorModel
        case .auto:
            // First 3 iterations: cheap model for tool calls and extraction
            // Later iterations: expensive model for synthesis and complex reasoning
            return iteration < 3 ? executorModel : advisorModel
        }
    }

    // MARK: - System prompt (with cache-aware fragments)

    /// Builds the system prompt as a fragment array. The prompt-cache boundary
    /// separates static content (tools, rules — cached between requests) from
    /// dynamic content (project context, date — changes per request).
    /// Providers that support prompt caching can reuse the static portion.
    private func buildSystemPrompt() -> String {
        let fragments = buildPromptFragments()
        return fragments.static + "\n\n" + fragments.dynamic
    }

    /// Returns separated static and dynamic prompt fragments.
    /// Static: tool definitions, behavior rules (cacheable across requests).
    /// Dynamic: project context, current date (changes per request).
    func buildPromptFragments() -> (static: String, dynamic: String) {
        let tools = registry.allDefinitions()
        let toolList = tools.map { t in
            let params = t.parameters.properties.keys.sorted().joined(separator: ", ")
            return "- `\(t.name)`\(params.isEmpty ? "" : "(\(params))"): \(t.description)"
        }.joined(separator: "\n")

        let staticPrompt = """
        You are Wawa, an AI assistant with access to the user's personal knowledge workspace.

        AVAILABLE TOOLS:
        \(toolList)

        HOW TO USE TOOLS:
        - Call tools using the exact function name. Arguments must be valid JSON.
        - Use search_knowledge to find information by keywords. Always search before answering.
        - Use get_item to fetch the full content of a specific item by its UUID.
        - Use list_items to browse by type, date range, or filter.
        - Use get_project to see a project's tasks and connected items.
        - Use get_connections to explore how items relate to each other.
        - Use think to ask a more capable reasoning model for help with complex analysis. Provide structured context, not raw data. The advisor returns only guidance.
        - Use create_note and create_task ONLY when the user explicitly asks. Confirm first.
        - Use list_prompts, read_prompt, and edit_prompt to inspect and modify system behavior. Always confirm before editing prompts.

        RULES:
        1. NEVER guess or make up facts. Always search or fetch before answering.
        2. Cite items by their title and ID when referencing them.
        3. If search returns no results, tell the user honestly and suggest alternatives.
        4. Be concise. Answer directly, then offer to explore further.
        5. For date-based queries, use today's date: see dynamic context below.
        6. Item IDs are UUIDs. Use exact IDs from search or list results.
        7. If you need clarification, ask.
        """

        var dynamicPrompt = "Today's date: \(Date().formatted(date: .complete, time: .omitted))."

        // Context-aware guidance
        if let ck = toolContext.contextKey {
            dynamicPrompt += "\n\nCURRENT CONTEXT: \(toolContext.contextDisplayName ?? ck)"
            switch ck {
            case "inbox":
                dynamicPrompt += "\n- The user is browsing their inbox. Use list_items to show unprocessed items."
                dynamicPrompt += "\n- Help triage: suggest archiving, assigning to projects, or flagging."
            case "explore:projects":
                dynamicPrompt += "\n- The user is browsing projects. Use get_project to explore specific ones."
                dynamicPrompt += "\n- Help compare projects, identify stalled ones, or suggest new project ideas."
            default:
                if ck.hasPrefix("project:") {
                    dynamicPrompt += "\n- The user is viewing this project. Use get_project to see tasks, items, and connections."
                    dynamicPrompt += "\n- Answer about status, risks, and progress. Suggest next steps."
                } else if ck.hasPrefix("item:") {
                    dynamicPrompt += "\n- The user is viewing this item. Use get_item to retrieve its full content."
                    dynamicPrompt += "\n- Answer detailed questions about this item's content."
                }
            }
        }

        if let projectID = toolContext.activeProjectID {
            dynamicPrompt += "\n\nCURRENT PROJECT:\n"
            if let name = toolContext.activeProjectName { dynamicPrompt += "- Project: \(name)\n" }
            dynamicPrompt += "- Project ID: \(projectID.uuidString)\n"
            dynamicPrompt += "- Use get_project to see tasks, items, and connections.\n"
            dynamicPrompt += "- Use create_task and create_edge to add to this project.\n"
            dynamicPrompt += "- When referencing items from this project, cite them by title and ID.\n"
            dynamicPrompt += "- Prioritize this project's context in all searches and answers."
        }

        if let itemID = toolContext.activeItemID {
            dynamicPrompt += "\n\nFOCUSED ITEM:\n- Item ID: \(itemID.uuidString)"
            dynamicPrompt += "\n- Use get_item to read its full content."
            dynamicPrompt += "\n- Prioritize information from this item when answering."
        }

        return (static: staticPrompt, dynamic: dynamicPrompt)
    }

    private func buildRequest(
        systemPrompt: String, contextMessages: [ChatMessage],
        tools: [AIToolDefinition], model: String
    ) -> AIRequest {
        var aiMessages: [AIMessage] = [AIMessage(role: .system, content: [.text(systemPrompt)])]
        for msg in contextMessages {
            let tc: [AIToolCall]? = msg.toolCalls?.compactMap { AIToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
            aiMessages.append(AIMessage(role: msg.role, content: [.text(msg.content)], toolCalls: tc, toolCallId: msg.toolCallId))
        }
        let params = AIConfigService.shared.requestParams(for: "agent", model: model)
        let hasTools = !tools.isEmpty
        return AIRequest(model: model, messages: aiMessages,
            temperature: params.temperature, maxTokens: params.maxTokens,
            tools: hasTools ? tools : nil, toolChoice: hasTools ? "auto" : nil)
    }

    private func parseArguments(_ json: String, toolName: String) -> [String: any Sendable] {
        guard !json.trimmingCharacters(in: .whitespaces).isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: any Sendable] = [:]
        for (k, v) in dict {
            if let s = v as? String { result[k] = s }
            else if let i = v as? Int { result[k] = i }
            else if let d = v as? Double { result[k] = d }
            else if let b = v as? Bool { result[k] = b }
            else if let a = v as? [String] { result[k] = a }
        }
        return result
    }
}
