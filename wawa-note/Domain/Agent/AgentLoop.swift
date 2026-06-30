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
  case truncated(reason: String, progress: String)  // max iterations reached before task completion
  case finished(citations: [ChatCitation])
  case error(Error)
}

// MARK: - Agent Loop

@MainActor
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
            continuation: continuation,
            streamTimeout: 60  // chat: 60s without events = hang detected
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
    maxIterations overrideIterations: Int? = nil,
    timeoutSeconds: TimeInterval = 600  // 10-minute default safety net
  ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          let toolDefs = tools.map { tool in
            AIToolDefinition(
              name: tool.name, description: tool.description, parameters: tool.parameters)
          }
          let startTime = Date()
          try await self.runLoop(
            initialMessage: task,
            initialRole: .system,
            systemPrompt: systemPrompt,
            tools: toolDefs,
            history: history,
            provider: provider,
            continuation: continuation,
            maxIterations: overrideIterations ?? self.maxIterations,
            toolRegistry: AgentToolRegistry(tools: tools),
            deadline: startTime.addingTimeInterval(timeoutSeconds),
            streamTimeout: 300  // autonomous: 5min without events before timeout
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
    toolRegistry customRegistry: AgentToolRegistry? = nil,
    deadline: Date = Date.distantFuture,
    streamTimeout: TimeInterval = 60  // per-iteration stream heartbeat (chat: 60s, autonomous: 300s)
  ) async throws {
    let effectiveRegistry = customRegistry ?? registry
    let iterations = maxIterations ?? self.maxIterations
    var messages = history
    messages.append(ChatMessage(conversationId: UUID(), role: initialRole, content: initialMessage))
    AppLog.event("agent", "User: \(initialMessage.prefix(200))")
    var allCitations: [ChatCitation] = []

    var consecutiveFailures = 0
    let maxConsecutiveFailures = 5

    for iteration in 0..<iterations {
      // Cooperative cancellation — allows ProcessingQueueService to cancel
      if Task.isCancelled {
        continuation.finish()
        return
      }
      // Deadline check prevents infinite hangs from stuck tool calls or API loops.
      // The pipeline marks the item as .failed so the user can retry manually.
      guard Date() < deadline else {
        AppLog.agent.error("Agent loop timeout — iteration \(iteration) — deadline reached")
        continuation.finish()
        return
      }
      // Circuit breaker: if the agent keeps hitting the same error on every
      // tool call for N consecutive iterations, stop — continuing is wasteful
      // (burns tokens without progress). The item is marked as .failed so the
      // user can adjust inputs and retry manually.
      guard consecutiveFailures < maxConsecutiveFailures else {
        AppLog.agent.error(
          "Agent circuit breaker tripped — \(consecutiveFailures) consecutive iterations with tool errors"
        )
        continuation.yield(
          .truncated(
            reason:
              "Agent stopped after \(consecutiveFailures) consecutive failed tool calls. Please review the inputs and retry.",
            progress: "\(iteration)/\(iterations) iterations"
          ))
        continuation.finish()
        return
      }
      continuation.yield(.thinking)
      let model = resolveModel(for: iteration)

      let (contextMessages, wasTruncated, truncatedCount) = contextManager.prepareMessages(
        history: messages, systemPrompt: systemPrompt, tools: tools,
        maxTokensBudget: contextManager.modelContextLimit * 80 / 100
      )

      var adjusted = contextMessages
      if wasTruncated {
        // Use .user role instead of .system — some providers (Gemini)
        // only accept a single systemInstruction at the top level.
        adjusted.insert(
          ChatMessage(
            conversationId: UUID(), role: .user,
            content:
              "[SYSTEM NOTE: \(truncatedCount) older messages were truncated due to token limits.]"
          ), at: 0)
      }

      // Capability check: only send tools if provider supports tool calling.
      // Otherwise, the LLM gets a text-only prompt and uses text-based commands.
      let effectiveTools = provider.capabilities.supportsToolCalling ? tools : []
      let request = buildRequest(
        systemPrompt: systemPrompt, contextMessages: adjusted, tools: effectiveTools, model: model)
      let stream = provider.sendStreaming(request)
      var fullContent = ""
      var thinkingContent = ""  // accumulated thinking/reasoning tokens
      var pendingToolCalls: [(id: String, name: String, arguments: String)] = []
      var currentTCID = ""
      var currentTCName: String?
      var currentTCArgs = ""

      // ── Stream heartbeat ──────────────────────────────────
      // If the provider stream doesn't emit any event for
      // `streamTimeout` seconds, force-finish the iteration to
      // prevent infinite hangs (e.g. network drop, server hang).
      let lastEventLock = NSLock()
      var lastStreamEvent = Date()
      let streamTask = Task {
        for try await event in stream {
          lastEventLock.withLock { lastStreamEvent = Date() }
          switch event {
          case .textDelta(let d):
            fullContent += d
            continuation.yield(.textDelta(d))
          case .thinkingDelta(let t):
            thinkingContent += t
            continuation.yield(.textDelta("[thinking]\(t)[/thinking]"))
          case .toolCallDelta(let id, let name, let args):
            if !currentTCID.isEmpty && id != currentTCID, let n = currentTCName {
              pendingToolCalls.append((id: currentTCID, name: n, arguments: currentTCArgs))
              currentTCArgs = ""
            }
            currentTCID = id
            if let n = name { currentTCName = n }
            if let a = args { currentTCArgs += a }
          case .finished: break
          }
        }
      }

      // Heartbeat monitor — runs in parallel, cancels the stream
      // if no event arrives within the timeout window.
      let heartbeatTask = Task {
        while !Task.isCancelled {
          let elapsed = Date().timeIntervalSince(lastEventLock.withLock { lastStreamEvent })
          if elapsed > streamTimeout {
            AppLog.agent.error(
              "Agent stream heartbeat timeout — no event for \(Int(elapsed))s (limit: \(Int(streamTimeout))s)"
            )
            streamTask.cancel()
            continuation.yield(
              .textDelta(
                "\n\n[Response timed out after \(Int(elapsed))s of inactivity. Please retry.]"))
            return
          }
          try? await Task.sleep(nanoseconds: 5_000_000_000)  // check every 5s
        }
      }

      defer { heartbeatTask.cancel() }
      try await streamTask.value
      // ── End heartbeat ─────────────────────────────────────
      if !currentTCID.isEmpty, let n = currentTCName {
        pendingToolCalls.append((id: currentTCID, name: n, arguments: currentTCArgs))
      }

      if !pendingToolCalls.isEmpty {
        // Mark message as thinking when there's text AND tool calls (shows thinking bubble)
        let isThinking = !fullContent.trimmingCharacters(in: .whitespaces).isEmpty
        messages.append(
          ChatMessage(
            conversationId: UUID(), role: .assistant, content: fullContent,
            toolCalls: pendingToolCalls.map {
              PersistedToolCall(id: $0.id, name: $0.name, arguments: $0.arguments, status: .running)
            },
            isThinking: isThinking))

        // Execute tool calls in parallel when multiple are requested.
        // Sequential fallback for single tools (common case, avoids TaskGroup overhead).
        if pendingToolCalls.count == 1, let tc = pendingToolCalls.first {
          await executeSingleTool(
            tc, registry: effectiveRegistry, messages: &messages,
            allCitations: &allCitations, continuation: continuation)
        } else {
          await withTaskGroup(of: (Int, ToolResult?).self) { group in
            for (idx, tc) in pendingToolCalls.enumerated() {
              group.addTask {
                let result = await self.executeSingleToolSync(tc, registry: effectiveRegistry)
                return (idx, result)
              }
            }
            // Collect results in order, keyed by original index
            var results: [(Int, ToolResult?)] = []
            for await r in group { results.append(r) }
            results.sort(by: { $0.0 < $1.0 })

            for (idx, resultOpt) in results {
              if let result = resultOpt {
                // Preserve the original tool-call ID so the provider
                // can match each result to its outstanding call.
                let tcId = pendingToolCalls[idx].id
                messages.append(
                  ChatMessage(
                    conversationId: UUID(), role: .tool,
                    content: (result.isError ? "TOOL ERROR: " : "") + result.content,
                    toolCallId: tcId, blocks: result.blocks))
                allCitations.append(contentsOf: result.citations)
              }
            }
          }
        }
        // Circuit breaker tracking: check whether all tool calls resulted
        // in errors. If every tool this iteration returned TOOL ERROR,
        // increment the failure counter. A single success resets it.
        let toolMessages = messages.suffix(pendingToolCalls.count)
        let allErrors =
          !toolMessages.isEmpty && toolMessages.allSatisfy { $0.content.hasPrefix("TOOL ERROR:") }
        if allErrors {
          consecutiveFailures += 1
          AppLog.agent.warning(
            "Circuit breaker: \(consecutiveFailures)/\(maxConsecutiveFailures) consecutive tool-error iterations"
          )
        } else if !toolMessages.isEmpty {
          consecutiveFailures = 0  // at least one tool succeeded
        }
      } else {
        AppLog.event("agent", "Response (no tool calls): \(fullContent.prefix(300))")
        messages.append(
          ChatMessage(
            conversationId: UUID(), role: .assistant, content: fullContent, citations: allCitations)
        )

        // No tool calls in this iteration — the LLM is just talking.
        // Reset the circuit breaker since no tool errors occurred.
        consecutiveFailures = 0

        // If the LLM responded with text but no tool calls, and we still have
        // iterations left, push back — the agent MUST use tools to complete tasks.
        // Use a request-local message (not persisted to chat history) to avoid
        // polluting the user's conversation with synthetic instructions.
        if iteration + 1 < iterations {
          let pushBack = ChatMessage(
            conversationId: UUID(), role: .user,
            content:
              "You must use the available tools to execute actions. Do not just describe what you would do — actually run the commands."
          )
          adjusted.append(pushBack)
          continue
        }

        // Last iteration, no tool calls — the model chose to respond
        // with text. This is a natural completion (the agent finished
        // its work and is summarizing), not truncation.
        continuation.yield(.finished(citations: allCitations))
        continuation.finish()
        return
      }
    }
    // Loop exhausted all iterations without an early finish — task not completed.
    let progress = "\(iterations)/\(iterations) iterations exhausted"
    continuation.yield(
      .truncated(
        reason: "Agent exhausted all iterations without completing the task.", progress: progress))
    continuation.finish()
  }

  // MARK: - Sub-agent spawning

  /// Spawns a sub-agent with a different provider and model for a focused task.
  /// The sub-agent runs with fewer tools (typically just ls/cat/find/grep) and
  /// returns its final text. Use this to delegate work to cheaper models.
  /// - Parameters:
  ///   - task: The task description for the sub-agent
  ///   - provider: The provider to use (e.g. local Ollama for simple search)
  ///   - model: The model to use (e.g. "llama-3.2-1b" for summarization)
  ///   - maxIterations: Max tool-calling iterations (default 3 — keep it focused)
  /// - Returns: The final text output from the sub-agent
  func spawnSubAgent(
    task: String,
    provider: any AIProvider,
    model: String,
    maxIterations: Int = 3
  ) async throws -> String {
    // Sub-agents get a focused toolset — read-only VFS tools, no destructive ops
    let safeTools: [any AgentTool] = registry.allTools().filter { tool in
      let name = tool.name.lowercased()
      // Allow: ls, cat, find, grep, cd, help, semantic
      // Deny: touch, echo, rm, mv, analyze, export
      return ["ls", "cat", "find", "grep", "cd", "help", "semantic"].contains(name)
    }

    let subAgent = AgentLoop(
      registry: AgentToolRegistry(tools: safeTools),
      toolContext: toolContext,
      maxIterations: maxIterations,
      mode: .fast,
      executorModel: model,
      advisorModel: model
    )

    var fullOutput = ""
    let stream = subAgent.runAutonomous(
      task: task,
      systemPrompt:
        "You are a focused sub-agent. Execute the task using read-only tools. Return a concise result.",
      tools: safeTools,
      provider: provider,
      maxIterations: maxIterations,
      timeoutSeconds: 120
    )

    for try await event in stream {
      if case .textDelta(let d) = event { fullOutput += d }
    }

    return fullOutput
  }

  // MARK: - Model resolution

  /// Dynamic model routing based on mode, iteration phase, AND budget state.
  /// In .auto mode: executor for iterations 0-2, advisor for 3+.
  /// When over budget, downgrades to executor (cheaper) model.
  private func resolveModel(for iteration: Int) -> String {
    // Budget check: if over daily limit, always use executor (cheapest)
    let budget = BudgetTracker.shared
    if budget.isOverBudget {
      AppLog.agent.warning("Budget: over daily limit — downgrading to executor model")
      return executorModel
    }

    switch mode {
    case .deep: return advisorModel
    case .fast: return executorModel
    case .auto:
      // When budget is <25%, use executor for all iterations
      if case .economy = budget.recommendedTier {
        return executorModel
      }
      // Standard: executor for first 3 iterations, advisor for synthesis
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
      let tc: [AIToolCall]? = msg.toolCalls?.compactMap {
        AIToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
      }
      aiMessages.append(
        AIMessage(
          role: msg.role, content: [.text(msg.content)], toolCalls: tc, toolCallId: msg.toolCallId))
    }
    let params = AIConfigService.shared.requestParams(for: "agent", model: model)
    let hasTools = !tools.isEmpty
    return AIRequest(
      model: model, messages: aiMessages,
      temperature: params.temperature, maxTokens: params.maxTokens,
      tools: hasTools ? tools : nil, toolChoice: hasTools ? "auto" : nil)
  }

  // MARK: - Tool execution helpers

  private func executeSingleTool(
    _ tc: (id: String, name: String, arguments: String),
    registry: AgentToolRegistry,
    messages: inout [ChatMessage],
    allCitations: inout [ChatCitation],
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
  ) async {
    continuation.yield(.toolCallStarted(name: tc.name, id: tc.id, arguments: tc.arguments))
    AppLog.event("agent", "Tool call: \(tc.name)(\(tc.arguments.prefix(120)))")

    guard let tool = registry.tool(named: tc.name) else {
      messages.append(
        ChatMessage(
          conversationId: UUID(), role: .tool,
          content: "TOOL ERROR: unknown tool '\(tc.name)'", toolCallId: tc.id))
      continuation.yield(.toolCallCompleted(name: tc.name, id: tc.id, summary: "Error"))
      return
    }

    let args = parseArguments(tc.arguments, toolName: tc.name)

    // Validate arguments against tool schema BEFORE execution
    if let validationError = tool.validateArguments(args) {
      AppLog.agent.warning("Tool arg validation failed for \(tc.name): \(validationError)")
      messages.append(
        ChatMessage(
          conversationId: UUID(), role: .tool,
          content:
            "ARGUMENT ERROR: \(validationError). Please correct your arguments and try again.",
          toolCallId: tc.id))
      continuation.yield(.toolCallCompleted(name: tc.name, id: tc.id, summary: "Invalid args"))
      return
    }

    let result: ToolResult
    do {
      result = try await executeWithTimeout(seconds: 120) {
        try await tool.execute(args, context: self.toolContext)
      }
    } catch {
      let errorMsg =
        error is TimeoutError
        ? "TOOL TIMEOUT: \(tc.name) exceeded 120s — hung or stuck"
        : "TOOL ERROR: \(tc.name): \(error.localizedDescription)"
      messages.append(
        ChatMessage(conversationId: UUID(), role: .tool, content: errorMsg, toolCallId: tc.id))
      continuation.yield(
        .toolCallCompleted(
          name: tc.name, id: tc.id, summary: error is TimeoutError ? "Timeout" : "Error"))
      return
    }

    allCitations.append(contentsOf: result.citations)
    continuation.yield(.toolCallCompleted(name: tc.name, id: tc.id, summary: result.displaySummary))
    let resultPreview = result.content.prefix(150).replacingOccurrences(of: "\n", with: " ")
    AppLog.event(
      "agent", "Tool result: \(tc.name) → \(result.isError ? "ERROR: " : "")\(resultPreview)")
    messages.append(
      ChatMessage(
        conversationId: UUID(), role: .tool,
        content: (result.isError ? "TOOL ERROR: " : "") + result.content, toolCallId: tc.id,
        blocks: result.blocks))
  }

  /// Synchronous wrapper for parallel execution — returns result instead of appending to messages.
  private func executeSingleToolSync(
    _ tc: (id: String, name: String, arguments: String),
    registry: AgentToolRegistry
  ) async -> ToolResult? {
    guard let tool = registry.tool(named: tc.name) else {
      return ToolResult(
        content: "TOOL ERROR: unknown tool '\(tc.name)'", isError: true,
        displaySummary: "Error")
    }
    let args = parseArguments(tc.arguments, toolName: tc.name)
    if let validationError = tool.validateArguments(args) {
      return ToolResult(
        content: "ARGUMENT ERROR: \(validationError)", isError: true,
        displaySummary: "Invalid args")
    }
    do {
      return try await executeWithTimeout(seconds: 120) {
        try await tool.execute(args, context: self.toolContext)
      }
    } catch {
      let msg =
        error is TimeoutError
        ? "TOOL TIMEOUT: \(tc.name) exceeded 120s"
        : "TOOL ERROR: \(tc.name): \(error.localizedDescription)"
      return ToolResult(
        content: msg, isError: true,
        displaySummary: error is TimeoutError ? "Timeout" : "Error")
    }
  }

  private func parseArguments(_ json: String, toolName: String) -> [String: any Sendable] {
    guard !json.trimmingCharacters(in: .whitespaces).isEmpty,
      let data = json.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    var result: [String: any Sendable] = [:]
    for (k, v) in dict {
      if let s = v as? String {
        result[k] = s
      } else if let i = v as? Int {
        result[k] = i
      } else if let d = v as? Double {
        result[k] = d
      } else if let b = v as? Bool {
        result[k] = b
      } else if let a = v as? [String] {
        result[k] = a
      }
    }
    return result
  }
}

// MARK: - Tool execution timeout

/// Thrown when a tool call exceeds its deadline.
struct TimeoutError: Error, LocalizedError {
  let toolName: String
  let seconds: Int
  var errorDescription: String? { "Tool '\(toolName)' timed out after \(seconds)s" }
}

/// Execute an async operation with a deadline. If the operation doesn't complete
/// within `seconds`, its Task is cancelled and `TimeoutError` is thrown.
/// Uses cooperative cancellation — the operation must check `Task.isCancelled`.
private func executeWithTimeout<T: Sendable>(
  seconds: Int,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
      throw TimeoutError(toolName: "unknown", seconds: seconds)
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw TimeoutError(toolName: "unknown", seconds: seconds)
    }
    return result
  }
}
