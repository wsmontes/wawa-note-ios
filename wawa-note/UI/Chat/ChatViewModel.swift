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

    enum ChatState {
        case idle
        case thinking
        case streaming
        case error
    }

    private let chatService = ChatService()
    private var modelContext: ModelContext?
    private var streamTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var hasObservedContext = false
    private var projectColorCache: [UUID: String] = [:]

    func projectColorHex(for projectID: UUID) -> String? {
        if let cached = projectColorCache[projectID] { return cached }
        guard let ctx = modelContext,
              let project = try? ProjectService(context: ctx).fetch(id: projectID),
              let hex = project.colorHex else { return nil }
        projectColorCache[projectID] = hex
        return hex
    }

    init() {
        loadConversations()
    }

    func setup(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Context

    func observeContext(from overlay: ChatOverlayState) {
        guard !hasObservedContext else { return }
        hasObservedContext = true
        switchToContext(overlay.context)
        overlay.$context
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newContext in
                self?.switchToContext(newContext)
            }
            .store(in: &cancellables)
    }

    private func switchToContext(_ context: ChatContext) {
        guard context != activeContext else { return }
        activeContext = context

        guard let conv = try? chatService.findOrCreateConversation(for: context) else { return }
        currentConversation = conv
        messages = (try? chatService.messages(for: conv.id)) ?? []
        streamingText = ""
        activeToolCalls = []
        state = .idle

        switch context {
        case .project(let id):
            activeProjectID = id
            activeProjectName = (try? ProjectService(context: modelContext!).fetch(id: id))?.name
            activeProjectColorHex = projectColorHex(for: id)
        case .item(let itemID):
            if let ctx = modelContext,
               let item = try? KnowledgeItemService(context: ctx).fetchItem(id: itemID),
               let pid = item.projectID {
                activeProjectID = pid
                activeProjectName = (try? ProjectService(context: ctx).fetch(id: pid))?.name
                activeProjectColorHex = projectColorHex(for: pid)
            } else {
                activeProjectID = nil
                activeProjectName = nil
                activeProjectColorHex = nil
            }
        default:
            activeProjectID = nil
            activeProjectName = nil
            activeProjectColorHex = nil
        }
        loadConversations()

        if messages.isEmpty {
            sendWelcome(for: context)
        }
    }

    private func sendWelcome(for context: ChatContext) {
        guard let ctx = modelContext,
              let provider = try? ProviderRouter.resolveActive(context: ctx),
              let conv = currentConversation else { return }
        let model = selectedModel.isEmpty ? "gpt-5-nano" : selectedModel

        let welcomePrompt: String = {
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
                let name = activeProjectName ?? "this project"
                return "Greet the user. One line. They're viewing \(name). Offer to help."
            }
        }()

        let systemPrompt = "You are a concise assistant. Respond with EXACTLY one short line. No tools, no follow-up, no questions. Just a warm, contextual welcome."
        let conversationId = conv.id

        let userMsg = ChatMessage(conversationId: conversationId, role: .user, content: welcomePrompt, projectColorHex: activeProjectColorHex)
        messages.append(userMsg)
        try? chatService.appendMessage(userMsg)
        state = .thinking

        streamTask = Task.detached { [weak self] in
            let request = AIRequest(
                model: model,
                messages: [
                    AIMessage(role: .system, content: [.text(systemPrompt)]),
                    AIMessage(role: .user, content: [.text(welcomePrompt)])
                ],
                temperature: 0.7
            )
            do {
                let response = try await provider.send(request)
                let assistantMsg = ChatMessage(
                    conversationId: conversationId, role: .assistant,
                    content: response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await MainActor.run {
                    self?.messages.append(assistantMsg)
                    try? self?.chatService.appendMessage(assistantMsg)
                    self?.state = .idle
                }
            } catch {
                await MainActor.run {
                    self?.messages.removeLast()
                    self?.state = .idle
                }
            }
        }
    }

    // MARK: - Actions

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .thinking, state != .streaming else { return }
        inputText = ""
        error = nil

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

        let userMsg = ChatMessage(conversationId: conv.id, role: .user, content: text, projectColorHex: activeProjectColorHex)
        messages.append(userMsg)
        try? chatService.appendMessage(userMsg)

        guard let ctx = modelContext else { error = "Model context not available."; return }

        // Resolve provider
        guard let provider = try? ProviderRouter.resolveActive(context: ctx) else {
            error = "No AI provider configured. Go to Settings."
            return
        }
        let model = selectedModel.isEmpty ? (try? ActiveProviderManager.shared.getActiveProvider(context: ctx))?.defaultModel ?? "gpt-5.5" : selectedModel

        state = .thinking
        streamingText = ""
        activeToolCalls = []
        let conversationId = conv.id

        let registry = AgentToolRegistry(tools: [
            SearchKnowledgeTool(), GetItemTool(), ListItemsTool(),
            GetProjectTool(), GetConnectionsTool(), GetTasksTool(),
            CreateNoteTool(), CreateTaskTool(), SummarizeDayTool(),
            GetAnalysisTool(), UpdateTaskTool(), CreateEdgeTool(),
            SetAnnotationTool(), TrashItemTool(), ThinkTool(),
            CreateProjectFrameworkTool(), UpdateProjectFrameworkTool(),
            // Prompt management (Phase 2)
            ListPromptsTool(), ReadPromptTool(), EditPromptTool(),
            // Agent memory (Phase 3)
            WriteMemoryTool(), SearchMemoryTool(), ListMemoriesTool(),
            // Plan mode (Phase 5)
            PlanCreateTool(), PlanUpdateTool(),
            // Output blocks
            RenderTableTool(), RenderActionsTool(), RenderCardTool(), RenderCodeTool(),
            RenderChartTool(),
            // JavaScript sandbox
            ExecuteJavaScriptTool()
        ])

        let toolContext = ToolContext(
            modelContext: ctx,
            activeProjectID: activeProjectID,
            activeProjectName: activeProjectName,
            activeItemID: activeContext.associatedID,
            contextKey: activeContext.key,
            contextDisplayName: activeContext.displayName,
            activeProjectColorHex: activeProjectColorHex,
            projectColorHexes: projectColorCache
        )
        let execModel = selectedModel.isEmpty ? "gpt-5-nano" : selectedModel
        let advModel = "gpt-5.5"
        let loop = AgentLoop(registry: registry, toolContext: toolContext, mode: mode, executorModel: execModel, advisorModel: advModel)

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = loop.runStreaming(userMessage: text, history: messages, provider: provider)

                var fullContent = ""
                var currentToolId = ""

                for try await event in stream {
                    if Task.isCancelled { break }

                    switch event {
                    case .thinking:
                        state = .thinking
                    case .textDelta(let delta):
                        state = .streaming
                        fullContent += delta
                        streamingText = fullContent
                    case .toolCallStarted(let name, let id, let args):
                        activeToolCalls.append(ToolCallProgress(id: id, toolName: name, status: .running, displaySummary: "Calling \(name)...", error: nil))
                        currentToolId = id
                    case .toolCallCompleted(let name, let id, let summary):
                        if let idx = activeToolCalls.firstIndex(where: { $0.id == id }) {
                            activeToolCalls[idx] = ToolCallProgress(id: id, toolName: name, status: .completed, displaySummary: summary, error: nil)
                        }
                    case .finished(let citations):
                        let assistantMsg = ChatMessage(
                            conversationId: conversationId,
                            role: .assistant,
                            content: fullContent,
                            citations: citations,
                            projectColorHex: activeProjectColorHex
                        )
                        messages.append(assistantMsg)
                        try? chatService.appendMessage(assistantMsg)
                        streamingText = ""
                        activeToolCalls = []
                        state = .idle
                    case .error(let err):
                        error = err.localizedDescription
                        state = .error
                    }
                }
            } catch {
                if !Task.isCancelled {
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
            guard !arg.isEmpty else { response = "Usage: /analyze <itemID>"; break }
            guard let itemId = UUID(uuidString: arg) else { response = "Invalid UUID: `\(arg)`."; break }
            NotificationCenter.default.post(name: .pipelineCompleted, object: itemId.uuidString,
                userInfo: ["action": "reprocess"])
            response = "Re-analysis triggered for item `\(arg)`. Check the Knowledge detail view for progress."
        case "prompt":
            guard !arg.isEmpty else { response = "Usage: /prompt <name>. Use /prompts to list names."; break }
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
            guard !all.isEmpty else { response = "No memories recorded yet."; break }
            response = all.map { "- \($0.isStale ? "[STALE] " : "")\($0.pattern) (\($0.successCount)S/\($0.failCount)F)" }.joined(separator: "\n")
        case "search":
            guard !arg.isEmpty else { response = "Usage: /search <query>"; break }
            guard let ctx = modelContext else { response = "Model context not available."; break }
            let items = (try? KnowledgeItemService(context: ctx).allItems()) ?? []
            let results = SearchService().searchNow(query: arg, in: items).prefix(5)
            guard !results.isEmpty else { response = "No results for \"\(arg)\"."; break }
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

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        state = .idle
    }

    func createNewConversation() {
        currentConversation = try? chatService.createConversation(contextKey: activeContext.key)
        messages = []
        streamingText = ""
        activeToolCalls = []
        state = .idle
        loadConversations()
    }

    func selectConversation(_ conv: ChatConversation) {
        currentConversation = conv
        messages = (try? chatService.messages(for: conv.id)) ?? []
    }

    func deleteConversation(_ conv: ChatConversation) {
        try? chatService.deleteConversation(id: conv.id)
        if currentConversation?.id == conv.id {
            currentConversation = nil
            messages = []
        }
        loadConversations()
    }

    func loadConversations() {
        conversations = (try? chatService.fetchConversations()) ?? []
    }
}
