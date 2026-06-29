import Combine
import SwiftData
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var state: ChatState = .idle
    @Published var streamingText: String = ""
    @Published var activeToolCalls: [ToolCallProgress] = []
    @Published var error: String?
    @Published var currentConversation: ChatConversation?
    @Published var conversations: [ChatConversation] = []
    @Published var selectedModel: String = ""
    @Published var mode: AgentMode = .auto
    @Published var activeProjectID: UUID?
    @Published var activeProjectName: String?
    @Published var activeContext: ChatContext = .global
    @Published var activeProjectColorHex: String?
    @Published var isGreetingLoading: Bool = false

    enum ChatState {
        case idle
        case thinking
        case streaming
        case error
    }

    private let chatService = ChatService()
    private var modelContext: ModelContext?
    private var streamTask: Task<Void, Never>?
    private var greetingTask: Task<Void, Never>?

    deinit {
        streamTask?.cancel()
        greetingTask?.cancel()
    }
    private var cancellables = Set<AnyCancellable>()
    private var hasObservedContext = false
    private var pendingContext: ChatContext?
    private var projectColorCache: [UUID: String] = [:]
    private var greetingCache: [String: String] = [:]
    private var lastUserMessage: String = ""

    func projectColorHex(for projectID: UUID) -> String? {
        if let cached = projectColorCache[projectID] { return cached }
        guard let ctx = modelContext,
            let project = try? ProjectService(context: ctx).fetch(id: projectID),
            let hex = project.colorHex
        else { return nil }
        projectColorCache[projectID] = hex
        return hex
    }

    init() {
    }

    /// Absolute fallback model name when no provider is configured. Uses the configured chat model default.
    private static var defaultChatModel: String {
        AIConfigService.shared.modelFor(feature: "chat")
    }

    func setup(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Context

    func observeContext(from overlay: ChatOverlayState) {
        guard !hasObservedContext else { return }
        hasObservedContext = true
        // Handle the initial context synchronously.
        switchToContext(overlay.context)

        // Observe context changes: if the chat overlay is already visible the
        // switch happens immediately; otherwise the change is deferred until
        // syncContextIfNeeded() is called (e.g. when the user taps the Chat tab).
        overlay.$context
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newContext in
                guard let self else { return }
                if overlay.isActive {
                    self.switchToContext(newContext)
                } else {
                    self.pendingContext = newContext
                }
            }
            .store(in: &cancellables)

        // When the chat overlay becomes active, apply any pending context change.
        overlay.$isActive
            .removeDuplicates()
            .sink { [weak self] isActive in
                if isActive {
                    self?.syncContextIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    /// Call when chat overlay opens to apply any pending context change.
    func syncContextIfNeeded() {
        if let pending = pendingContext, pending != activeContext {
            switchToContext(pending)
        }
        pendingContext = nil
    }

    private func switchToContext(_ context: ChatContext) {
        // Resolve the effective context: items that belong to a project redirect to
        // the project context so the chat shares the project's conversation history.
        let effectiveContext = resolveContext(context)

        if effectiveContext != context {
            AppLog.event("chat", "Context resolved: \(context.key) → \(effectiveContext.key)")
        }

        guard effectiveContext != activeContext else {
            AppLog.event("chat", "Context unchanged: \(effectiveContext.key), skipping switch")
            return
        }
        AppLog.event("chat", "Switching context: \(activeContext.key) → \(effectiveContext.key)")
        streamTask?.cancel()
        streamTask = nil
        greetingTask?.cancel()

        // Persist any partial streaming response before switching away
        if !streamingText.isEmpty, let oldConv = currentConversation {
            let partialMsg = ChatMessage(
                conversationId: oldConv.id, role: .assistant,
                content: streamingText + "\n\n_[Interrupted]_",
                projectColorHex: activeProjectColorHex
            )
            try? chatService.appendMessage(partialMsg)
        }

        activeContext = effectiveContext

        guard let conv = try? chatService.findOrCreateConversation(for: effectiveContext) else { return }
        currentConversation = conv
        var loaded = (try? chatService.messages(for: conv.id)) ?? []
        // Strip old greeting prompt messages (internal prompts mistakenly persisted as user messages)
        loaded.removeAll { $0.role == .user && $0.content.hasPrefix("Greet the user") }
        messages = loaded
        streamingText = ""
        activeToolCalls = []
        state = .idle
        isGreetingLoading = false

        switch effectiveContext {
        case .project(let id):
            activeProjectID = id
            // Clear before fetch so stale values from a previous project are
            // never displayed if the database lookup fails.
            activeProjectName = nil
            activeProjectColorHex = nil
            guard let ctx = modelContext else { break }
            let svc = ProjectService(context: ctx)
            if let project = try? svc.fetch(id: id) {
                activeProjectName = project.name
                if let hex = project.colorHex {
                    activeProjectColorHex = hex
                } else {
                    let fallback = ProjectPalette.allHexes.first!
                    try? svc.setColor(id, hex: fallback)
                    activeProjectColorHex = fallback
                }
                // Inject context setup as real tool calls in conversation history
                injectProjectContext(project: project, conversationId: conv.id)
            }
        case .item(let itemID):
            // Standalone item (no parent project) — use its own context
            activeProjectID = nil
            activeProjectName = nil
            activeProjectColorHex = nil
            // Store the item ID for the agent to know which item is in focus
            if let ctx = modelContext,
                let item = try? KnowledgeItemService(context: ctx).fetchItem(id: itemID)
            {
                // No project context injection for standalone items
                // The agent will see the item context via activeItemID in ToolContext
                _ = item
            }
        default:
            activeProjectID = nil
            activeProjectName = nil
            activeProjectColorHex = nil
        }
        loadConversations()

        if messages.isEmpty {
            if let cached = greetingCache[effectiveContext.key] {
                insertCachedGreeting(cached, conversationId: conv.id)
            } else {
                generateWelcome(for: effectiveContext)
            }
        }
    }

    /// Resolves an item context to its parent project context when the item belongs
    /// to a project. Items without projects keep their own context.
    private func resolveContext(_ context: ChatContext) -> ChatContext {
        guard case .item(let itemID) = context,
            let ctx = modelContext,
            let item = try? KnowledgeItemService(context: ctx).fetchItem(id: itemID),
            let pid = item.projectID
        else {
            return context
        }
        return .project(pid)
    }

    // MARK: - Context injection

    /// Injects synthetic `cd` + `ls` messages into the conversation so the agent
    /// sees the project navigation as already completed. This prevents the agent
    /// from re-exploring on every new conversation.
    private func injectProjectContext(project: Project, conversationId: UUID) {
        guard let ctx = modelContext else { return }
        let slug = project.slug.replacingOccurrences(of: "/", with: "-")
        let tasks = (try? TaskService(context: ctx).tasks(for: project.id)) ?? []
        let items = (try? ProjectService(context: ctx).items(in: project.id)) ?? []

        // Only inject if the conversation is empty (first open)
        let existing = (try? chatService.messages(for: conversationId)) ?? []
        if !existing.isEmpty { return }

        // Build synthetic ls output
        var taskLines = ""
        for t in tasks.prefix(20) {
            taskLines += "  \(t.id.uuidString).json  [\(t.statusRaw)]  \(t.title)  priority=\(t.priorityRaw)\n"
        }
        var itemLines = ""
        for it in items.prefix(10) {
            itemLines += "  \(it.id.uuidString.prefix(8)).json  [\(it.typeRaw)]  \(it.title)  (\(it.statusRaw))\n"
        }

        let lsOutput = """
            /projects/\(slug)/  (\(project.name))
            project.json   \(project.statusRaw.capitalized)  health=\(project.healthStatus ?? "N/A")  tasks=\(tasks.count)  items=\(items.count)
            items/         \(items.count) item(s)
            tasks/         \(tasks.count) task(s)
            people/        People connected to this project
            edges/         Graph relationships
            signals/       Alerts and insights
            analysis/      AI analyses + transcripts (use cat)
            """

        // Create synthetic tool call and result messages with proper blocks for UI rendering
        let cdArgs = "{\"command\":\"cd /projects/\(slug)\"}"
        let cdMsg = ChatMessage(
            conversationId: conversationId, role: .assistant,
            content: "",
            toolCalls: [PersistedToolCall(id: UUID().uuidString, name: "run_command", arguments: cdArgs, status: .completed)],
            blocks: [.text("cd /projects/\(slug)/")]
        )
        let cdResult = ChatMessage(
            conversationId: conversationId, role: .tool,
            content: "/projects/\(slug)/  (\(project.name))",
            toolCallId: cdMsg.toolCalls?.first?.id,
            blocks: [
                .projectContext(
                    ProjectContextData(
                        projectName: project.name, slug: slug, status: project.statusRaw,
                        taskCount: tasks.count, itemCount: items.count, signalCount: 0,
                        healthStatus: project.healthStatus, summary: "Current project context"
                    ))
            ]
        )
        let lsArgs = "{\"command\":\"ls\"}"
        let lsMsg = ChatMessage(
            conversationId: conversationId, role: .assistant,
            content: "",
            toolCalls: [PersistedToolCall(id: UUID().uuidString, name: "run_command", arguments: lsArgs, status: .completed)],
            blocks: [.text("ls")]
        )
        let lsResult = ChatMessage(
            conversationId: conversationId, role: .tool,
            content: lsOutput,
            toolCallId: lsMsg.toolCalls?.first?.id,
            blocks: [.text(lsOutput)]
        )

        try? chatService.appendMessages([cdMsg, cdResult, lsMsg, lsResult])
        messages.append(contentsOf: [cdMsg, cdResult, lsMsg, lsResult])
    }

    // MARK: - Greeting cache

    func pregenerateGreeting(for context: ChatContext) {
        let key = context.key
        guard greetingCache[key] == nil, let ctx = modelContext,
            let provider = try? ProviderRouter.resolveActive(context: ctx)
        else { return }

        let welcomePrompt = Self.welcomePrompt(for: context, projectName: activeProjectName)
        let systemPrompt = Self.systemPrompt

        // Resolve model respecting the active provider — never hardcode a model name
        let model =
            selectedModel.isEmpty
            ? (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel ?? Self.defaultChatModel
            : selectedModel
        let params = AIConfigService.shared.requestParams(for: "chat", model: model)

        greetingTask?.cancel()
        greetingTask = Task { @MainActor [weak self] in
            let request = AIRequest(
                model: model,
                messages: [
                    AIMessage(role: .system, content: [.text(systemPrompt)]),
                    AIMessage(role: .user, content: [.text(welcomePrompt)]),
                ],
                temperature: params.temperature,
                maxTokens: params.maxTokens
            )
            do {
                let response = try await provider.send(request)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self?.greetingCache[key] = text
                }
            } catch {
                // Silently fail — will generate on-demand when chat opens
            }
        }
    }

    func invalidateGreeting(for context: ChatContext) {
        greetingCache[context.key] = nil
    }

    private static func welcomePrompt(for context: ChatContext, projectName: String?) -> String {
        switch context {
        case .global:
            return "Greet the user briefly. One line. They just opened Wawa Note."
        case .inbox:
            return "Greet the user. One line. They're in their inbox reviewing captured items. Be warm."
        case .item:
            return "Acknowledge the user is viewing an item. One line. Offer to help analyze it."
        case .exploreProjects:
            return "Greet the user. One line. They're browsing projects. Offer to help navigate."
        case .project:
            let name = projectName ?? "this project"
            return "Greet the user. One line. They're viewing \(name). Offer to help."
        }
    }

    private static let systemPrompt =
        "You are a concise assistant. Respond with EXACTLY one short line. No tools, no follow-up, no questions. Just a warm, contextual welcome."

    // MARK: - Greeting generation (on-demand, no prompt in chat)

    private func generateWelcome(for context: ChatContext) {
        guard let ctx = modelContext,
            let provider = try? ProviderRouter.resolveActive(context: ctx),
            let conv = currentConversation
        else { return }

        // Resolve model respecting the active provider — same pattern as sendMessage()
        let model =
            selectedModel.isEmpty
            ? (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel ?? Self.defaultChatModel
            : selectedModel
        let params = AIConfigService.shared.requestParams(for: "chat", model: model)

        let welcomePrompt = Self.welcomePrompt(for: context, projectName: activeProjectName)
        let systemPrompt = Self.systemPrompt
        let conversationId = conv.id
        let contextKey = context.key

        isGreetingLoading = true
        streamingText = "..."

        greetingTask = Task { @MainActor [weak self] in
            let request = AIRequest(
                model: model,
                messages: [
                    AIMessage(role: .system, content: [.text(systemPrompt)]),
                    AIMessage(role: .user, content: [.text(welcomePrompt)]),
                ],
                temperature: params.temperature,
                maxTokens: params.maxTokens
            )
            do {
                let response = try await provider.send(request)
                let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self?.isGreetingLoading = false
                    // Insert greeting BEFORE clearing streamingText to avoid
                    // the frame where both are empty (prevents emptyState flash)
                    self?.insertCachedGreeting(content, conversationId: conversationId)
                    self?.streamingText = ""
                    self?.greetingCache[contextKey] = content
                }
            } catch {
                await MainActor.run {
                    self?.streamingText = ""
                    self?.isGreetingLoading = false
                    self?.state = .idle
                }
            }
        }
    }

    private func insertCachedGreeting(_ text: String, conversationId: UUID) {
        let assistantMsg = ChatMessage(
            conversationId: conversationId, role: .assistant,
            content: text, projectColorHex: activeProjectColorHex
        )
        messages.append(assistantMsg)
        try? chatService.appendMessage(assistantMsg)
        state = .idle
    }

    // MARK: - Actions

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .thinking, state != .streaming, !isGreetingLoading else { return }
        inputText = ""
        error = nil
        lastUserMessage = text
        // Cancel any in-progress greeting — user explicitly sent a message
        greetingTask?.cancel()
        greetingTask = nil

        // Handle commands (Phase 4)
        if text.hasPrefix("/") {
            handleCommand(text)
            return
        }

        // Ensure conversation exists
        if currentConversation == nil {
            currentConversation = try? chatService.createConversation(
                title: String(text.prefix(60)),
                contextKey: activeContext.key
            )
            loadConversations()
        }

        guard let conv = currentConversation else { return }
        guard let ctx = modelContext else {
            error = "Model context not available."
            return
        }

        let userMsg = ChatMessage(conversationId: conv.id, role: .user, content: text, projectColorHex: activeProjectColorHex)
        messages.append(userMsg)
        try? chatService.appendMessage(userMsg)

        // Resolve provider
        guard let provider = try? ProviderRouter.resolveActive(context: ctx) else {
            error = "No AI provider configured. Go to Settings."
            return
        }
        let model =
            selectedModel.isEmpty ? (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel ?? Self.defaultChatModel : selectedModel

        state = .thinking
        streamingText = ""
        activeToolCalls = []
        let conversationId = conv.id

        let registry = AgentToolRegistry(tools: [
            ShellTool()
        ])

        let slugForContext = activeProjectID.flatMap { pid in
            try? ProjectService(context: ctx).fetch(id: pid)?.slug.replacingOccurrences(of: "/", with: "-")
        }
        let toolContext = ToolContext(
            modelContext: ctx,
            activeProjectID: activeProjectID,
            activeProjectName: activeProjectName,
            activeProjectSlug: slugForContext,
            activeItemID: activeContext.associatedID,
            contextKey: activeContext.key,
            contextDisplayName: activeContext.displayName,
            activeProjectColorHex: activeProjectColorHex,
            projectColorHexes: projectColorCache
        )
        let activeDefaultModel = (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel
        let execModel = selectedModel.isEmpty ? (activeDefaultModel ?? ChatViewModel.defaultChatModel) : selectedModel
        let advModel = selectedModel.isEmpty ? (activeDefaultModel ?? ChatViewModel.defaultChatModel) : selectedModel
        let loop = AgentLoop(registry: registry, toolContext: toolContext, mode: mode, executorModel: execModel, advisorModel: advModel)

        // Prevent the app from suspending the AgentLoop when backgrounded.
        // beginBackgroundTask gives us ~30s to finish the current iteration
        // and save progress before iOS suspends the app (see [#3]).
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "chat.agentLoop") {
            AppLog.event("chat", "Background task expiring — cancelling AgentLoop")
            self.streamTask?.cancel()
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }
            do {
                let stream = loop.runStreaming(userMessage: text, history: messages, provider: provider)

                var fullContent = ""
                var wasCancelled = false

                for try await event in stream {
                    if Task.isCancelled {
                        wasCancelled = true
                        break
                    }

                    switch event {
                    case .thinking:
                        state = .thinking
                    case .textDelta(let delta):
                        state = .streaming
                        fullContent += delta
                        streamingText = fullContent
                    case .toolCallStarted(let name, let id, let args):
                        activeToolCalls.append(ToolCallProgress(id: id, toolName: name, status: .running, displaySummary: "Calling \(name)...", error: nil))
                    case .toolCallCompleted(let name, let id, let summary):
                        if let idx = activeToolCalls.firstIndex(where: { $0.id == id }) {
                            activeToolCalls[idx] = ToolCallProgress(id: id, toolName: name, status: .completed, displaySummary: summary, error: nil)
                        }
                    case .finished(let citations):
                        guard !wasCancelled else { break }
                        let assistantMsg = ChatMessage(
                            conversationId: conversationId,
                            role: .assistant,
                            content: fullContent,
                            citations: citations,
                            projectColorHex: activeProjectColorHex
                        )
                        messages.append(assistantMsg)
                        try? chatService.appendMessage(assistantMsg)
                        // Propagate ToolContext changes so the next message starts
                        // with the correct project state (covers agent-initiated `cd`)
                        if toolContext.activeProjectID != activeProjectID {
                            activeProjectID = toolContext.activeProjectID
                            activeProjectName = toolContext.activeProjectName ?? activeProjectName
                            if let pid = toolContext.activeProjectID {
                                activeProjectColorHex = projectColorHex(for: pid)
                            } else {
                                activeProjectColorHex = nil
                            }
                        }
                        streamingText = ""
                        activeToolCalls = []
                        state = .idle
                    case .truncated(let reason, let progress):
                        guard !wasCancelled else { break }
                        // Agent was cut off by iteration limit — persist partial
                        // work and show "Continue?" prompt to the user.
                        let truncatedMsg = ChatMessage(
                            conversationId: conversationId,
                            role: .assistant,
                            content: fullContent + "\n\n⚠️ \(reason) (\(progress))",
                            projectColorHex: activeProjectColorHex
                        )
                        messages.append(truncatedMsg)
                        try? chatService.appendMessage(truncatedMsg)
                        streamingText = ""
                        activeToolCalls = []
                        state = .idle
                    case .error(let err):
                        streamingText = ""
                        activeToolCalls = []
                        error = err.localizedDescription
                        state = .error
                    }
                }
            } catch {
                if !Task.isCancelled {
                    // Propagate context even on error (partial work may have been done)
                    if toolContext.activeProjectID != activeProjectID {
                        activeProjectID = toolContext.activeProjectID
                        activeProjectName = toolContext.activeProjectName ?? activeProjectName
                    }
                    streamingText = ""
                    activeToolCalls = []
                    self.error = error.localizedDescription
                    state = .error
                }
            }
        }
    }

    // MARK: - Commands (Phase 4)

    private func handleCommand(_ text: String) {
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
        let cmd = parts.first.map(String.init) ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""

        let response: String
        switch cmd {
        case "help":
            response = """
                **Commands:**
                - `/analyze <itemID>` — Run content pipeline on an item
                - `/prompt <name>` — Show a prompt template (use `list_prompts` for names)
                - `/search <query>` — Search the knowledge base
                - `/memories` — List agent memories
                - `/prompts` — List all prompt templates
                - `/help` — Show this help
                """
        case "analyze":
            guard !arg.isEmpty else {
                response = "Usage: /analyze <itemID>"
                break
            }
            guard let itemId = UUID(uuidString: arg) else {
                response = "Invalid UUID: `\(arg)`."
                break
            }
            NotificationCenter.default.post(
                name: .pipelineCompleted, object: itemId.uuidString,
                userInfo: ["action": "reprocess"])
            response = "Re-analysis triggered for item `\(arg)`. Check the Knowledge detail view for progress."
        case "prompt":
            guard !arg.isEmpty else {
                response = "Usage: /prompt <name>. Use /prompts to list names."
                break
            }
            if let p = PromptStore.shared.prompt(named: arg) {
                response = "**\(p.name)** [\(p.category)]\(p.isUserEdited ? " (edited)" : "")\n\n\(p.content)"
            } else {
                response = "Prompt `\(arg)` not found. Use /prompts to list available templates."
            }
        case "prompts":
            let all = PromptStore.shared.prompts()
            response = all.map { "- `\($0.name)` [\($0.category)]\($0.isUserEdited ? " (edited)" : "")" }.joined(separator: "\n")
        case "memories":
            let all = AgentMemoryStore.shared.listAll()
            guard !all.isEmpty else {
                response = "No memories recorded yet."
                break
            }
            response = all.map { "- \($0.isStale ? "[STALE] " : "")\($0.pattern) (\($0.successCount)S/\($0.failCount)F)" }.joined(separator: "\n")
        case "search":
            guard !arg.isEmpty else {
                response = "Usage: /search <query>"
                break
            }
            guard let ctx = modelContext else {
                response = "Model context not available."
                break
            }
            let items = (try? KnowledgeItemService(context: ctx).allItems()) ?? []
            let results = SearchService(fileStore: FileArtifactStore()).searchNow(query: arg, in: items).prefix(5)
            guard !results.isEmpty else {
                response = "No results for \"\(arg)\"."
                break
            }
            response = results.map { r in
                guard let item = items.first(where: { $0.id == r.itemID }) else { return "- Unknown item" }
                return "- \(item.title) (\(item.type.label)) — \(r.snippet)"
            }.joined(separator: "\n")
        default:
            response = "Unknown command: `\(cmd)`. Use `/help` to see available commands."
        }

        // Display response as system message (no agent involved)
        if let conv = currentConversation {
            let sysMsg = ChatMessage(conversationId: conv.id, role: .assistant, content: response)
            messages.append(sysMsg)
            try? chatService.appendMessage(sysMsg)
        }
    }

    func retryLastMessage() {
        guard !lastUserMessage.isEmpty, state != .thinking, state != .streaming else { return }
        sendInternalMessage(lastUserMessage)
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        state = .idle
    }

    func createNewConversation() {
        streamTask?.cancel()
        streamTask = nil
        greetingTask?.cancel()
        greetingTask = nil

        // Create with explicit error handling
        let newConv: ChatConversation?
        do {
            newConv = try chatService.createConversation(contextKey: activeContext.key)
        } catch {
            AppLog.error("chat", "Failed to create new conversation: \(error)")
            newConv = nil
        }

        currentConversation = newConv
        messages = []
        streamingText = ""
        activeToolCalls = []
        state = .idle
        isGreetingLoading = false
        error = nil
        greetingCache[activeContext.key] = nil
        loadConversations()

        // Re-inject project context for the new conversation if applicable
        if let pid = activeProjectID, let ctx = modelContext,
            let project = try? ProjectService(context: ctx).fetch(id: pid),
            let conv = currentConversation
        {
            injectProjectContext(project: project, conversationId: conv.id)
            messages = (try? chatService.messages(for: conv.id)) ?? []
            messages.removeAll { $0.role == .user && $0.content.hasPrefix("Greet the user") }
        }

        // Generate greeting for the fresh conversation
        if messages.isEmpty, let conv = currentConversation {
            if let cached = greetingCache[activeContext.key] {
                insertCachedGreeting(cached, conversationId: conv.id)
            } else if newConv != nil {
                generateWelcome(for: activeContext)
            }
        }
    }

    func selectConversation(_ conv: ChatConversation) {
        currentConversation = conv
        var loaded = (try? chatService.messages(for: conv.id)) ?? []
        loaded.removeAll { $0.role == .user && $0.content.hasPrefix("Greet the user") }
        messages = loaded
        streamingText = ""
        activeToolCalls = []
        state = .idle
        isGreetingLoading = false

        // Update active context to match the selected conversation
        if let key = conv.contextKey, let ctx = ChatContext.from(key: key) {
            activeContext = ctx
            switch ctx {
            case .project(let id):
                activeProjectID = id
                if let mctx = modelContext,
                    let project = try? ProjectService(context: mctx).fetch(id: id)
                {
                    activeProjectName = project.name
                    activeProjectColorHex = project.colorHex ?? projectColorHex(for: id)
                }
            case .item:
                activeProjectID = nil
                activeProjectName = nil
                activeProjectColorHex = nil
            default:
                activeProjectID = nil
                activeProjectName = nil
                activeProjectColorHex = nil
            }
        }
    }

    func deleteConversation(_ conv: ChatConversation) {
        try? chatService.deleteConversation(id: conv.id)
        if currentConversation?.id == conv.id {
            currentConversation = nil
            messages = []
        }
        loadConversations()
    }

    /// Send a message internally — adds the user message to the chat and triggers the agent
    /// WITHOUT showing the text in the input field. Used for UI-driven interactions like
    /// ChoicePrompt buttons, Confirmation dialogs, and quick-action suggestions.
    func sendInternalMessage(_ text: String) {
        guard !text.isEmpty, state != .thinking, state != .streaming, !isGreetingLoading else { return }
        error = nil
        // Cancel any in-progress greeting
        greetingTask?.cancel()
        greetingTask = nil

        if currentConversation == nil {
            currentConversation = try? chatService.createConversation(
                title: String(text.prefix(60)),
                contextKey: activeContext.key
            )
            loadConversations()
        }

        guard let conv = currentConversation, let ctx = modelContext else { return }

        lastUserMessage = text
        let userMsg = ChatMessage(
            conversationId: conv.id, role: .user, content: text,
            projectColorHex: activeProjectColorHex, isInternal: true)
        // Internal messages go to agent history but NOT rendered as user bubbles
        messages.append(userMsg)
        try? chatService.appendMessage(userMsg)

        // Resolve provider and start agent loop
        guard let provider = try? ProviderRouter.resolveActive(context: ctx) else {
            error = "No AI provider configured. Go to Settings."
            return
        }
        let model =
            selectedModel.isEmpty ? (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel ?? Self.defaultChatModel : selectedModel

        state = .thinking
        streamingText = ""
        activeToolCalls = []
        let conversationId = conv.id

        let registry = AgentToolRegistry(tools: [ShellTool()])

        let slugForContext = activeProjectID.flatMap { pid in
            try? ProjectService(context: ctx).fetch(id: pid)?.slug.replacingOccurrences(of: "/", with: "-")
        }
        let toolContext = ToolContext(
            modelContext: ctx,
            activeProjectID: activeProjectID,
            activeProjectName: activeProjectName,
            activeProjectSlug: slugForContext,
            activeItemID: activeContext.associatedID,
            contextKey: activeContext.key,
            contextDisplayName: activeContext.displayName,
            activeProjectColorHex: activeProjectColorHex,
            projectColorHexes: projectColorCache
        )
        let activeDefaultModel = (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel
        let execModel = selectedModel.isEmpty ? (activeDefaultModel ?? ChatViewModel.defaultChatModel) : selectedModel
        let advModel = selectedModel.isEmpty ? (activeDefaultModel ?? ChatViewModel.defaultChatModel) : selectedModel
        let loop = AgentLoop(registry: registry, toolContext: toolContext, mode: mode, executorModel: execModel, advisorModel: advModel)

        // Prevent the app from suspending the AgentLoop when backgrounded.
        // beginBackgroundTask gives us ~30s to finish the current iteration
        // and save progress before iOS suspends the app (see [#3]).
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "chat.agentLoop") {
            AppLog.event("chat", "Background task expiring — cancelling AgentLoop")
            self.streamTask?.cancel()
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }
            do {
                let stream = loop.runStreaming(userMessage: text, history: messages, provider: provider)

                var fullContent = ""
                var wasCancelled = false
                for try await event in stream {
                    if Task.isCancelled {
                        wasCancelled = true
                        break
                    }

                    switch event {
                    case .thinking:
                        state = .thinking
                    case .textDelta(let delta):
                        state = .streaming
                        fullContent += delta
                        streamingText = fullContent
                    case .toolCallStarted(let name, let id, let args):
                        activeToolCalls.append(ToolCallProgress(id: id, toolName: name, status: .running, displaySummary: "Calling \(name)...", error: nil))
                    case .toolCallCompleted(let name, let id, let summary):
                        if let idx = activeToolCalls.firstIndex(where: { $0.id == id }) {
                            activeToolCalls[idx] = ToolCallProgress(id: id, toolName: name, status: .completed, displaySummary: summary, error: nil)
                        }
                    case .finished(let citations):
                        guard !wasCancelled else { break }
                        let assistantMsg = ChatMessage(
                            conversationId: conversationId,
                            role: .assistant,
                            content: fullContent,
                            citations: citations,
                            projectColorHex: activeProjectColorHex
                        )
                        messages.append(assistantMsg)
                        try? chatService.appendMessage(assistantMsg)
                        if toolContext.activeProjectID != activeProjectID {
                            activeProjectID = toolContext.activeProjectID
                            activeProjectName = toolContext.activeProjectName ?? activeProjectName
                            if let pid = toolContext.activeProjectID {
                                activeProjectColorHex = projectColorHex(for: pid)
                            } else {
                                activeProjectColorHex = nil
                            }
                        }
                        streamingText = ""
                        activeToolCalls = []
                        state = .idle
                    case .truncated(let reason, let progress):
                        guard !wasCancelled else { break }
                        let truncatedMsg = ChatMessage(
                            conversationId: conversationId,
                            role: .assistant,
                            content: fullContent + "\n\n⚠️ \(reason) (\(progress))",
                            projectColorHex: activeProjectColorHex
                        )
                        messages.append(truncatedMsg)
                        try? chatService.appendMessage(truncatedMsg)
                        streamingText = ""
                        activeToolCalls = []
                        state = .idle
                    case .error(let err):
                        streamingText = ""
                        activeToolCalls = []
                        error = err.localizedDescription
                        state = .error
                    }
                }
            } catch {
                if !Task.isCancelled {
                    if toolContext.activeProjectID != activeProjectID {
                        activeProjectID = toolContext.activeProjectID
                        activeProjectName = toolContext.activeProjectName ?? activeProjectName
                    }
                    streamingText = ""
                    activeToolCalls = []
                    self.error = error.localizedDescription
                    state = .error
                }
            }
        }
    }

    /// Execute a shell command directly (no agent) and show the result as a tool message.
    /// Used ONLY for actual shell commands from UI (ProjectContextCard quick actions like "ls tasks/").
    /// For user choices/prompts, use sendInternalMessage instead.
    func runCommandDirectly(_ command: String) {
        guard let ctx = modelContext, let conv = currentConversation else { return }
        let slug = activeProjectID.flatMap { pid in try? ProjectService(context: ctx).fetch(id: pid)?.slug.replacingOccurrences(of: "/", with: "-") }
        let toolCtx = ToolContext(modelContext: ctx, activeProjectID: activeProjectID, activeProjectName: activeProjectName, activeProjectSlug: slug)
        let result = ShellInterpreter.execute(command: command, context: toolCtx)

        // Add assistant tool call + result to messages — internal (not shown as chat bubbles)
        let tc = PersistedToolCall(id: UUID().uuidString, name: "run_command", arguments: "{\"command\":\"\(command)\"}", status: .completed)
        let assistantMsg = ChatMessage(
            conversationId: conv.id, role: .assistant, content: "",
            toolCalls: [tc], blocks: nil, isInternal: true)
        let resultMsg = ChatMessage(
            conversationId: conv.id, role: .tool,
            content: result.isError ? "TOOL ERROR: \(result.content)" : result.content,
            toolCallId: tc.id, blocks: result.blocks, isInternal: true)
        messages.append(assistantMsg)
        messages.append(resultMsg)
        try? chatService.appendMessages([assistantMsg, resultMsg])
    }

    func clearCurrentConversation() {
        guard let conv = currentConversation else { return }
        try? chatService.deleteConversation(id: conv.id)
        currentConversation = try? chatService.createConversation(contextKey: activeContext.key)
        messages = []
        streamingText = ""
        activeToolCalls = []
        state = .idle
        greetingCache[activeContext.key] = nil
        loadConversations()
    }

    func loadConversations() {
        conversations = (try? chatService.fetchConversations()) ?? []
    }
}
