import SwiftUI
import SwiftData
import Combine

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
              let hex = project.colorHex else { return nil }
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
               let item = try? KnowledgeItemService(context: ctx).fetchItem(id: itemID) {
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
              let pid = item.projectID else {
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
            blocks: [.projectContext(ProjectContextData(
                projectName: project.name, slug: slug, status: project.statusRaw,
                taskCount: tasks.count, itemCount: items.count, signalCount: 0,
                healthStatus: project.healthStatus, summary: "Current project context"
            ))]
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
        // Static greetings — no LLM API call, no tokens, no latency.
        // LLM-generated greetings cost money and add async complexity
        // before the core chat flow is stable.
        let key = context.key
        guard greetingCache[key] == nil else { return }
        greetingCache[key] = Self.staticGreeting(for: context, projectName: activeProjectName)
    }

    func invalidateGreeting(for context: ChatContext) {
        greetingCache[context.key] = nil
    }

    private static func staticGreeting(for context: ChatContext, projectName: String?) -> String {
        switch context {
        case .global:       return "Welcome back. What would you like to explore?"
        case .inbox:        return "Here's your inbox. Ready to review what you've captured."
        case .item:         return "You're viewing an item. I can help analyze it."
        case .exploreProjects: return "Browsing projects. Ask me to help navigate."
        case .project:      return "You're in \(projectName ?? "your project"). How can I help?"
        }
    }

    // MARK: - Greeting (static, no LLM call)

    private func generateWelcome(for context: ChatContext) {
        guard let conv = currentConversation else { return }
        let text = Self.staticGreeting(for: context, projectName: activeProjectName)
        greetingCache[context.key] = text
        if messages.isEmpty {
            let greeting = ChatMessage(conversationId: conv.id, role: .assistant, content: text)
            messages.append(greeting)
            try? chatService.appendMessage(greeting)
        }
        state = .idle
    }


