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
        maxIterations: Int? = nil,
        mode: AgentMode = .auto,
        executorModel: String = AIConfigService.shared.modelFor(feature: "chat"),
        advisorModel: String = AIConfigService.shared.modelFor(feature: "chat")
    ) {
        self.registry = registry
        self.toolContext = toolContext
        // Deep mode gets more iterations for complex multi-step tasks (plan + execute)
        self.maxIterations = maxIterations ?? (mode == .deep ? 24 : (mode == .fast ? 6 : 12))
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
        AppLog.event("agent", "User: \(initialMessage.prefix(200))")
        var allCitations: [ChatCitation] = []

        for iteration in 0..<iterations {
            // Cooperative cancellation — allows ProcessingQueueService to cancel
            if Task.isCancelled { continuation.finish(); return }
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
                // Mark message as thinking when there's text AND tool calls (shows thinking bubble)
                let isThinking = !fullContent.trimmingCharacters(in: .whitespaces).isEmpty
                messages.append(ChatMessage(conversationId: UUID(), role: .assistant, content: fullContent,
                    toolCalls: pendingToolCalls.map { PersistedToolCall(id: $0.id, name: $0.name, arguments: $0.arguments, status: .running) },
                    isThinking: isThinking))

                for tc in pendingToolCalls {
                    continuation.yield(.toolCallStarted(name: tc.name, id: tc.id, arguments: tc.arguments))
                    AppLog.event("agent", "Tool call: \(tc.name)(\(tc.arguments.prefix(120)))")

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
                    let resultPreview = result.content.prefix(150).replacingOccurrences(of: "\n", with: " ")
                    AppLog.event("agent", "Tool result: \(tc.name) → \(result.isError ? "ERROR: " : "")\(resultPreview)")
                    messages.append(ChatMessage(conversationId: UUID(), role: .tool,
                        content: (result.isError ? "TOOL ERROR: " : "") + result.content, toolCallId: tc.id,
                        blocks: result.blocks))
                }
            } else {
                AppLog.event("agent", "Response: \(fullContent.prefix(300))")
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
        let staticPrompt = """
        You are Wawa, an assistant in the user's personal knowledge workspace. You help capture, organize, and explore knowledge using a virtual filesystem accessed through run_command.

        [CORE RULES]
        1. ONE COMMAND PER CALL. No &&, ||, ;, or pipes. cd, then ls/cat in the next call.
        2. NEVER show UUIDs or technical IDs to the user. Reference items by title, not ID.
        3. The [CURRENT STATE] section below is authoritative — do not re-verify with ls / or ls /projects.
        4. For choices, use numbered lists (1. Option A, 2. Option B). They become buttons.
        5. touch /inbox/ for ITEMS. touch tasks/ for TASKS. echo '{...}' > path to UPDATE.
        6. rm is soft delete (items) or permanent (tasks). mv moves between inbox and projects.
        7. ERROR: read it, fix it, retry once. Never retry the same failing command twice.
        8. DESTRUCTIVE commands (rm tasks, echo overwriting data): ask user first with ask_user --yes "Proceed" --no "Cancel"

        [COMPLEX TASK HANDLING]
        When the user asks you to reorganize, restructure, audit, or perform multi-step work:
        8. FIRST, explore the current state (cd, ls, cat) to understand what exists.
        9. THEN, create a plan as numbered steps. Announce the plan to the user.
        10. Create tasks for each step using: touch tasks/ --title "Step 1: ..."
        11. Work through the tasks one by one. After completing each, mark it done:
            echo '{"status":"done"}' > tasks/task-title
        12. After all tasks are done, summarize what was accomplished.
        13. If the user confirms the plan, proceed immediately without asking again.

        [INTERACTION RULES]
        14. You CAN write text AND call a tool in the same response. The text is shown
            to the user as you work. Use this to narrate your progress.
        15. To ask the user a question WHILE continuing to iterate, use:
            ask_user "question" --yes "Confirm" --no "Cancel"
            ask_user "Pick one:" --options "Option A,Option B,Option C"
            ask_user "What should I name this?" --text --placeholder "Name..." --submit "Save"
            The user's response (choice or free text) is sent to you, and you continue working.
        16. The loop ENDS only when you respond with text and NO tool calls.
            As long as you call a tool, you keep iterating — even 20+ times.
        17. You are free to iterate. Explore, plan, act, ask — don't stop until done.

        [QUICK REFERENCE — use 'help' for details]
        ls <path>  List contents. Flags: --long --type --status --tag --since --limit
        cd <path>  Change directory. cd .. to go up.
        cat <path> Read a file. --json for raw data.
        find <path> --tag X --since 7d --type audio. In tasks/ dir: finds tasks.
        grep "text" <path>  Full-text search. Also works on analysis/ and transcript files.
        touch <path> --title "Name" --priority high --owner "Name"
        echo '{"field":"value"}' > <path>  Update item, task, project.
        help <command>  Show detailed docs for any command.
        help vfs  Show the virtual filesystem layout.

        [DOCUMENT CREATION]
        Create rich, well-structured documents as notes. Use markdown for formatting.
        After creating, write the full body with echo '...' > items/{id}/body.md
        Use --document-type to announce what kind of document you're creating.

        Meeting Summary:
        # Meeting: {title}  |  **Date:** ... **Duration:** ...
        ## Summary  {paragraph}  ## Decisions  | Decision | Owner | Status |  ## Action Items  - [ ] Task (@owner)

        Status Report:
        # Status Report: {project}  |  **Period:** start - end
        ## Progress  {paragraph}  ## Metrics  | Metric | Value | Change |  ## Risks  ## Next Steps

        Decision Log:
        # Decision: {title}  |  **Date:** ... **Status:** Confirmed|Pending|Rejected
        ## Context  {paragraph}  ## Decision  {paragraph}  ## Rationale  ## Consequences

        Checklist:
        # Checklist: {title}
        - [ ] Task (@owner, Due: date)  - [x] Completed task

        Research Notes:
        # Research: {topic}  |  ## Sources  ## Analysis  ## Conclusions  ## Citations

        Comparative Table:
        # Comparison: {topic}
        | Feature | A | B |  |---|---|---|  | Price | ... | ... |

        Digest:
        # {Period} Digest  |  ## Highlights  ## Stats  | Metric | Value |  ## Items Processed

        Always use: touch items/ --title "Title" --type note --document-type meeting-summary --body "summary"
        Then: echo '# Full markdown...' > items/{id}/body.md
        The user will see a card they can tap to open the document.

        [NEW COMMANDS]
        semantic "query" --limit 10    Semantic search (needs embedding model)
        analyze <item-id>             Trigger pipeline processing on an item
        cal list / cal add --title "X" --start "..." --end "..."   Calendar events
        export <id> --format md|json  Export item or project
        vision <item-id> --question "..." --save-as-note   Analyze image with AI
        progress <step> <total> --label "..."   Show progress bar in chat
        find /inbox/ --type note --exec "analyze {id}"   Batch process items ({id}, {title})
        touch /inbox/ --type webBookmark --title "..." --url "https://..."   Create bookmark
        touch /inbox/ --type journalEntry --title "..." --mood great --body "..."   Journal with mood
        echo 'text' >> items/{id}/body.md   Append to file (>> = append, > = overwrite)
        """

        var dynamicPrompt = "Today's date: \(Date().formatted(date: .complete, time: .omitted))."

        // Context-aware guidance — filesystem edition
        if let slug = toolContext.activeProjectSlug, let pid = toolContext.activeProjectID {
            dynamicPrompt += "\n\nCURRENT DIRECTORY: /projects/\(slug)/"
            dynamicPrompt += "\nProject ID: \(pid.uuidString.prefix(8))"
            if let name = toolContext.activeProjectName {
                dynamicPrompt += "\nProject: \(name)"
            }
            dynamicPrompt += "\nUse ls to list contents, cat to read files, touch to create tasks."
        } else if toolContext.contextKey == "inbox" {
            dynamicPrompt += "\n\nCURRENT DIRECTORY: /inbox/"
            dynamicPrompt += "\nUse ls to see unprocessed items. Use mv to assign items to projects."
        } else if let ck = toolContext.contextKey {
            switch ck {
            case "explore:projects":
                dynamicPrompt += "\n\nCURRENT CONTEXT: Explore > Projects"
                dynamicPrompt += "\nUse ls /projects to browse all projects."
            default:
                if ck.hasPrefix("project:") {
                    dynamicPrompt += "\n\nCURRENT CONTEXT: Viewing a project. Use ls and cat to explore it."
                } else if ck.hasPrefix("item:") {
                    dynamicPrompt += "\n\nCURRENT CONTEXT: Viewing an item. Use cat to read its content."
                }
            }
        }

        if let itemID = toolContext.activeItemID {
            dynamicPrompt += "\n\nFOCUSED ITEM: \(itemID.uuidString.prefix(8))"
            dynamicPrompt += "\nUse cat to read its full content."
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
