import Foundation
import SwiftData
import OSLog

// MARK: - Ingestion models (Codable)

struct IngestionResponse: Codable {
    var item_project_view: String?
    var project_item_view: String?
    var connections: [IngestionConnection]?
    var task_updates: [IngestionTaskUpdate]?
    var new_tasks: [IngestionNewTask]?
    var edge_reinforcements: [IngestionReinforcement]?
    var insights: [IngestionInsight]?
    var project_summary_contribution: String?
    var project_summary_update: String? // legacy key, also checked
    var signals: [IngestionSignal]?
}

struct IngestionConnection: Codable {
    var from_title: String
    var to_title: String
    var type: String
    var explanation: String?
}

struct IngestionTaskUpdate: Codable {
    var task_title: String
    var new_status: String
    var reason: String?
}

struct IngestionNewTask: Codable {
    var title: String
    var priority: String?
    var reason: String?
    var confidence: Double?
}

struct IngestionReinforcement: Codable {
    var from_title: String?
    var to_title: String?
    var note: String?
}

struct IngestionInsight: Codable {
    var text: String
    var confidence: Double?
}

struct IngestionSignal: Codable {
    var type: String        // risk, alert, opportunity, contradiction, pattern, doubt, new_project, emerging_problem
    var title: String
    var body: String?
    var impact: Double?     // 0-1
    var urgency: Double?    // 0-1
    var related_item_titles: [String]?
}

// MARK: - Pipeline

@MainActor
final class ProjectIngestionPipeline: ObservableObject {
    private let ingestionState: ProjectIngestionState
    private let fileStore: FileArtifactStore

    /// Caps concurrent AI ingestion calls to avoid API rate limiting (HTTP 429).
    private var activeIngestionCount = 0
    private let maxConcurrentIngestions = 2

    init(ingestionState: ProjectIngestionState, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.ingestionState = ingestionState
        self.fileStore = fileStore
    }

    func ingest(itemID: UUID, projectID: UUID, using modelContext: ModelContext) async {
        guard self.activeIngestionCount < self.maxConcurrentIngestions else {
            AppLog.provider.warning("ProjectIngestion: rate limited (\(self.activeIngestionCount) active)")
            return
        }
        self.activeIngestionCount += 1
        defer { self.activeIngestionCount -= 1 }
        await runIngestion(itemID: itemID, projectID: projectID, context: modelContext)
    }

    // MARK: - Errors

    enum IngestionError: Error, LocalizedError {
        case noProvider
        case itemNotFound
        case projectNotFound
        case aiFailed(String)
        case jsonParseFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProvider: return "No AI provider configured. Go to Settings to add one."
            case .itemNotFound: return "Item not found."
            case .projectNotFound: return "Project not found."
            case .aiFailed(let msg): return "AI call failed: \(msg)"
            case .jsonParseFailed(let msg): return "Failed to parse AI response: \(msg)"
            }
        }
    }

    // MARK: - Private

    private func runIngestion(itemID: UUID, projectID: UUID, context: ModelContext) async {
        AppLog.provider.info("ProjectIngestion: starting for item \(itemID) → project \(projectID)")
        ingestionState.start(projectID)

        guard let provider = try? ProviderRouter.resolveActive(context: context) else {
            AppLog.provider.error("ProjectIngestion: NO AI PROVIDER configured. Cannot enrich project \(projectID). Go to Settings to add one.")
            postIngestionFailed(itemID: itemID, projectID: projectID, error: .noProvider)
            return
        }

        let projSvc = ProjectService(context: context)
        let knowledgeSvc = KnowledgeItemService(context: context)
        let taskSvc = TaskService(context: context)
        let edgeSvc = GraphEdgeService(context: context)
        guard let project = try? projSvc.fetch(id: projectID),
              let newItem = try? knowledgeSvc.fetchItem(id: itemID) else {
            AppLog.provider.error("ProjectIngestion: project \(projectID) or item \(itemID) NOT FOUND in SwiftData")
            postIngestionFailed(itemID: itemID, projectID: projectID, error: .projectNotFound)
            return
        }

        AppLog.provider.info("ProjectIngestion: project=\(project.name), item=\(newItem.title), provider=\(provider.id)")

        let allItems = (try? projSvc.items(in: projectID)) ?? []
        let existingTasks = (try? taskSvc.tasks(for: projectID)) ?? []

        // 1. Build comprehensive context
        let projectContext = buildProjectContext(
            project: project,
            items: allItems,
            tasks: existingTasks,
            edges: edgeSvc,
            fileStore: fileStore,
            excluding: itemID
        )
        let itemContext = buildItemContext(item: newItem, fileStore: fileStore)

        // 2. Check for critical doubts — hold ingestion if configured
        if project.holdIngestionForDoubts {
            let allSignals = (try? context.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
            let criticalDoubts = allSignals.filter {
                $0.projectID == projectID && $0.type == "doubt" && $0.isCritical && $0.isActive
            }
            if !criticalDoubts.isEmpty {
                AppLog.provider.info("ProjectIngestion: holding ingestion for project \(projectID) — \(criticalDoubts.count) critical doubt(s)")
                ingestionState.finish(projectID)
                return
            }
        }

        // 3. Resolve framework for domain-aware synthesis
        let framework = FrameworkService.shared.resolve(for: project)
        // 4. Prompt: dual-perspective, framework-aware
        let systemPrompt = buildSystemPrompt(for: project, framework: framework)
        let prompt = buildIngestionPrompt(projectContext: projectContext, newItemContext: itemContext, framework: framework)
        let model = ModelTierResolver.resolveForIngestion(projectID: projectID, context: context)
        let params = AIConfigService.shared.requestParams(for: "project_ingestion", model: model)
        AppLog.provider.info("ProjectIngestion: using model=\(model) for project \(project.name) (\(allItems.count) items)")

        let previousSummary = project.summary ?? ""

        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(prompt)])
            ],
            temperature: params.temperature,
            maxTokens: params.maxTokens,
            responseFormat: .jsonObject
        )

        do {
            let response = try await sendWithRetry(provider: provider, request: request, maxRetries: 3)
            let rawContent = response.content
            AppLog.provider.info("ProjectIngestion: raw response (\(rawContent.count) chars): \(String(rawContent.prefix(500)))")

            if let json = parseIngestionJSON(rawContent) {
                applyResults(response: json, newItem: newItem, project: project, allItems: allItems,
                            existingTasks: existingTasks, edgeSvc: edgeSvc, taskSvc: taskSvc,
                            context: context, previousSummary: previousSummary, framework: framework)
                AppLog.provider.info("ProjectIngestion: SUCCESS — \(json.new_tasks?.count ?? 0) new tasks, \(json.connections?.count ?? 0) connections for project \(project.name)")
                postIngestionCompleted(itemID: itemID, projectID: projectID)
                scheduleGraphAnalysis(projectID: projectID, context: context)
                return
            }

            saveRawIngestionResponse(rawContent, itemID: itemID, label: "raw")
            AppLog.provider.warning("ProjectIngestion: initial parse failed. Retrying with JSON fix prompt...")

            let fixPrompt = buildFixPrompt(originalPrompt: prompt, rawContent: rawContent, framework: framework)

            let fixRequest = AIRequest(
                model: model,
                messages: [
                    AIMessage(role: .system, content: [.text("You are a JSON repair assistant. Output ONLY valid JSON matching the requested schema.")]),
                    AIMessage(role: .user, content: [.text(fixPrompt)])
                ],
                responseFormat: AIConfigService.shared.supportsJSONFormat(for: model) ? .jsonObject : nil
            )

            do {
                let fixResponse = try await provider.send(fixRequest)
                saveRawIngestionResponse(fixResponse.content, itemID: itemID, label: "fix_attempt")
                if let json = parseIngestionJSON(fixResponse.content) {
                    AppLog.provider.info("ProjectIngestion: JSON fix retry succeeded")
                    applyResults(response: json, newItem: newItem, project: project, allItems: allItems,
                                existingTasks: existingTasks, edgeSvc: edgeSvc, taskSvc: taskSvc,
                                context: context, previousSummary: previousSummary, framework: framework)
                    postIngestionCompleted(itemID: itemID, projectID: projectID)
                    scheduleGraphAnalysis(projectID: projectID, context: context)
                    return
                }
            } catch {
                AppLog.provider.error("ProjectIngestion: JSON fix retry failed: \(error)")
            }

            AppLog.provider.error("ProjectIngestion: all parse attempts failed for item \(itemID)")
            postIngestionFailed(itemID: itemID, projectID: projectID, error: .jsonParseFailed("All parse attempts failed after JSON fix retry"))
        } catch {
            AppLog.provider.error("ProjectIngestion: AI call failed after retries: \(error)")
            postIngestionFailed(itemID: itemID, projectID: projectID, error: .aiFailed(error.localizedDescription))
        }
    }

    private func postIngestionCompleted(itemID: UUID, projectID: UUID) {
        ingestionState.finish(projectID)
    }

    /// Schedule cross-item graph intelligence analysis after ingestion succeeds.
    /// Runs fire-and-forget — results are persisted as annotations on project items.
    private func scheduleGraphAnalysis(projectID: UUID, context: ModelContext) {
        Task { @MainActor in
            let intelligence = GraphIntelligenceService(context: context, fileStore: FileArtifactStore())
            let hypotheses = await intelligence.analyzeGraph(for: projectID)
            guard !hypotheses.isEmpty else { return }
            for h in hypotheses {
                let annotation = Annotation(
                    source: "graph_intelligence",
                    key: h.type.rawValue,
                    value: h.text,
                    itemID: projectID,
                    confidence: h.confidence
                )
                context.insert(annotation)
            }
            try? context.save()
            AppLog.provider.info("ProjectIngestion: graph analysis found \(hypotheses.count) hypotheses for project \(projectID)")
        }
    }

    private func postIngestionFailed(itemID: UUID, projectID: UUID, error: IngestionError) {
        ingestionState.setError(projectID, message: error.localizedDescription)
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(for project: Project, framework: ProjectFramework) -> String {
        // Use framework's synthesis prompt for custom frameworks
        let basePrompt: String
        if framework.id != "builtin/meeting" {
            basePrompt = framework.projectSynthesis.systemPrompt
        } else {
            basePrompt = """
            You are a project knowledge analyst. You analyze how a new item relates to a project.

            KEY PRINCIPLES:
            - A new item does NOT make you rethink the entire project. It ADDS to existing knowledge.
            - Read the new item THROUGH the project's eyes: how does it fit, connect, extend?
            - Read the project THROUGH the new item's eyes: what does it reveal, confirm, or change?
            - NEVER suggest deleting tasks or connections. Tasks can change status (done/cancelled). Connections can be added.
            - Be conservative. Only report what is clearly supported. Flag uncertainty.
            """
        }

        var prompt = basePrompt + "\n\n"

        if let instructions = project.customInstructions, !instructions.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += """
            PROJECT INSTRUCTIONS (from user):
            \(instructions)

            Use these instructions to guide your analysis. Prioritize what the user cares about.

            """
        }

        let edgeTypeList = framework.edgeTypes.joined(separator: "|")

        prompt += """
        Return JSON with these fields:
        {
          "item_project_view": "one sentence: how this item fits into the project's existing knowledge",
          "project_item_view": "one sentence: what this item reveals about the project that was not clear before",
          "connections": [{"from_title": "...", "to_title": "...", "type": "\(edgeTypeList)", "explanation": "..."}],
          "task_updates": [{"task_title": "...", "new_status": "done|cancelled", "reason": "..."}],
          "new_tasks": [{"title": "...", "priority": "low|medium|high", "reason": "..."}],
          "edge_reinforcements": [{"from_title": "...", "to_title": "...", "note": "this connection is confirmed by the new item"}],
          "insights": [{"text": "...", "confidence": 0.8}],
          "signals": [{"type": "risk|alert|opportunity|contradiction|pattern|doubt|new_project|emerging_problem", "title": "Short signal name", "body": "Why this matters", "impact": 0.7, "urgency": 0.5, "related_item_titles": ["item A"]}],
          "project_summary_contribution": "REQUIRED. One paragraph summarizing what new knowledge this item contributes to the project."
        }

        SIGNAL DETECTION:
        After analysis, detect any significant signals:
        - risk: things that could go wrong (deadlines, missing info, blockers)
        - alert: urgent issues needing immediate attention
        - opportunity: things to explore, leverage, or act on
        - contradiction: this item conflicts with an existing item or assumption
        - pattern: a recurring theme across 3+ items
        - doubt: something unclear that needs investigation
        - new_project: this item hints at a separate project/initiative
        - emerging_problem: a problem that is just starting to surface
        Only raise signals that are clearly supported. Include impact (0-1) and urgency (0-1). Max 5 signals.

        RULES:
        - project_summary_contribution is REQUIRED. Always return it, even if just one sentence.
        - task_updates: ONLY update status if the new item CLEARLY indicates a task is done or no longer relevant. Never delete.
        - connections: report genuine relationships. Use types: \(edgeTypeList). If a connection already exists, use edge_reinforcements.
        - new_tasks: only tasks explicitly implied. Max 3.
        - signals: only the most relevant signals. Max 5. Omit if nothing notable.
        """

        return prompt
    }

    // MARK: - Context builders

    private func buildProjectContext(
        project: Project,
        items: [KnowledgeItem],
        tasks: [TaskItem],
        edges: GraphEdgeService,
        fileStore: FileArtifactStore,
        excluding itemID: UUID
    ) -> String {
        var ctx = "PROJECT: \(project.name)\n"

        // Summary
        if let summary = project.summary, !summary.isEmpty {
            ctx += "Summary: \(summary)\n\n"
        }

        // ALL items with their summaries
        let otherItems = items.filter { $0.id != itemID }
            .sorted { ($0.updatedAt) > ($1.updatedAt) }

        if !otherItems.isEmpty {
            ctx += "ITEMS (\(otherItems.count) total):\n"
            for (i, item) in otherItems.enumerated() {
                // Truncate only at extreme limits (500 items, not 10)
                if ctx.count > 30000 { ctx += "... (+\(otherItems.count - i) more items, truncated for space)\n"; break }
                ctx += "\n\(i+1). " + ItemContextBuilder.buildItemSummary(item: item, fileStore: fileStore)
            }
            ctx += "\n"
        }

        // ALL tasks (not just 10)
        if !tasks.isEmpty {
            ctx += "TASKS (\(tasks.count) total):\n"
            for t in tasks {
                if ctx.count > 30000 { ctx += "... (+ remaining tasks, truncated)\n"; break }
                ctx += "- [\(t.statusRaw)] \(t.title)"
                if let owner = t.ownerName { ctx += " | owner: \(owner)" }
                if let due = t.dueAt { ctx += " | due: \(due.formatted(date: .abbreviated, time: .omitted))" }
                ctx += "\n"
            }
            ctx += "\n"
        }

        // Existing graph edges (sampled if too many)
        let allEdges = collectAllEdges(for: otherItems.map(\.id), using: edges)
        if !allEdges.isEmpty {
            ctx += "EXISTING CONNECTIONS (\(allEdges.count) total):\n"
            for e in allEdges {
                if ctx.count > 30000 { ctx += "... (+ more connections, truncated)\n"; break }
                let fromTitle = otherItems.first(where: { $0.id == e.fromID })?.title ?? String(e.fromID.uuidString.prefix(8))
                let toTitle = otherItems.first(where: { $0.id == e.toID })?.title ?? String(e.toID.uuidString.prefix(8))
                ctx += "- \(fromTitle) → \(e.edgeType.rawValue) → \(toTitle)\n"
            }
            ctx += "\n"
        }

        return ctx
    }

    private func collectAllEdges(for itemIDs: [UUID], using edgeSvc: GraphEdgeService) -> [GraphEdge] {
        var all: [GraphEdge] = []
        for id in itemIDs {
            if let outgoing = try? edgeSvc.edges(from: id) { all.append(contentsOf: outgoing) }
            if let incoming = try? edgeSvc.edges(to: id) { all.append(contentsOf: incoming) }
        }
        // Deduplicate by id
        var seen: Set<UUID> = []
        return all.filter { seen.insert($0.id).inserted }
    }

    private func buildItemContext(item: KnowledgeItem, fileStore: FileArtifactStore) -> String {
        "NEW ITEM:\n" + ItemContextBuilder.buildItemContext(item: item, fileStore: fileStore)
    }

    // MARK: - Prompt

    private func buildIngestionPrompt(projectContext: String, newItemContext: String, framework: ProjectFramework) -> String {
        """
        Analyze this new item in the context of this project.

        === PROJECT KNOWLEDGE ===
        \(projectContext)

        === NEW ITEM ===
        \(newItemContext)

        === ANALYSIS TASK ===

        PART A — Item through project eyes:
        How does this item fit into the existing project? What does it add, confirm, or extend?

        PART B — Project through item eyes:
        Reading the project with the knowledge from this item — what becomes clearer? What was uncertain that is now confirmed or extended?

        Return JSON as specified in the system prompt.
        """
    }

    private func buildFixPrompt(originalPrompt: String, rawContent: String, framework: ProjectFramework) -> String {
        let edgeTypeList = framework.edgeTypes.joined(separator: "|")
        let schema = """
        {
          "connections": [{"from_title":"...","to_title":"...","type":"\(edgeTypeList)","explanation":"..."}],
          "task_updates": [{"task_title":"...","new_status":"done|cancelled","reason":"..."}],
          "new_tasks": [{"title":"...","priority":"low|medium|high","reason":"...","confidence":0.8}],
          "edge_reinforcements": [{"from_title":"...","to_title":"...","note":"..."}],
          "insights": [{"text":"...","confidence":0.8}],
          "project_summary_contribution": "..."
        }
        """
        return """
        Original task: \(originalPrompt.prefix(1000))...

        Your previous response was not valid JSON. Fix it to match this schema:

        \(schema)

        Your broken response: \(ProviderAdapter.normalizeJSON(rawContent).prefix(1500))

        Return ONLY valid JSON matching the schema. No markdown, no code fences.
        """
    }

    // MARK: - Apply results

    private func applyResults(
        response: IngestionResponse,
        newItem: KnowledgeItem,
        project: Project,
        allItems: [KnowledgeItem],
        existingTasks: [TaskItem],
        edgeSvc: GraphEdgeService,
        taskSvc: TaskService,
        context: ModelContext,
        previousSummary: String,
        framework: ProjectFramework
    ) {
        // Task status updates (never delete)
        if let updates = response.task_updates {
            let auth = FieldAuthorityService.shared
            let sugSvc = SuggestionGatingService(context: context)
            for update in updates {
                if let task = findTask(byTitle: update.task_title, in: existingTasks),
                   let newStatus = TaskStatus(rawValue: update.new_status) {
                    if auth.canModify(field: "status", of: task, by: .llm) {
                        try? taskSvc.updateStatus(task, to: newStatus)
                    } else {
                        sugSvc.proposeTaskUpdate(
                            taskTitle: task.title, field: "status",
                            proposedValue: update.new_status,
                            projectID: project.id,
                            sourceItemID: newItem.id,
                            reason: update.reason ?? "Pipeline suggests this update"
                        )
                    }
                }
            }
        }

        // New tasks — dedup by title against existing tasks
        if let newTasks = response.new_tasks {
            let existingTitles = Set(existingTasks.map { $0.title.lowercased().trimmingCharacters(in: .whitespaces) })
            for t in newTasks.prefix(3) {
                let normalized = t.title.lowercased().trimmingCharacters(in: .whitespaces)
                guard !existingTitles.contains(normalized) else {
                    AppLog.provider.info("ProjectIngestion: skipping duplicate task \"\(t.title)\"")
                    continue
                }
                let priority = t.priority.flatMap(TaskPriority.init(rawValue:)) ?? .medium
                try? taskSvc.create(
                    title: t.title, projectID: project.id, priority: priority,
                    sourceItemID: newItem.id, confidence: t.confidence,
                    createdBy: .llm
                )
            }
        }

        // New connections
        if let connections = response.connections {
            for conn in connections.prefix(5) {
                let fromItem = findItem(byTitle: conn.from_title, in: allItems) ?? newItem
                guard let toItem = findItem(byTitle: conn.to_title, in: allItems) else { continue }

                let edgeType = edgeType(from: conn.type)
                try? edgeSvc.create(fromID: fromItem.id, toID: toItem.id, edgeType: edgeType, provenanceItemID: newItem.id)
            }
        }

        // Edge reinforcements — update weight on existing edges
        if let reinforcements = response.edge_reinforcements {
            for r in reinforcements {
                guard let fromTitle = r.from_title,
                      let toTitle = r.to_title,
                      let fromItem = findItem(byTitle: fromTitle, in: allItems),
                      let toItem = findItem(byTitle: toTitle, in: allItems) else { continue }
                try? edgeSvc.reinforce(fromID: fromItem.id, toID: toItem.id)
            }
        }

        // Insights — persist as annotations on the new item
        if let insights = response.insights {
            for insight in insights.prefix(5) {
                let annotation = Annotation(
                    source: "project_ingestion",
                    key: "ai_insight",
                    value: insight.text,
                    itemID: newItem.id,
                    confidence: insight.confidence
                )
                context.insert(annotation)
            }
            try? context.save()
        }

        // Signals — create AgentSuggestions for detected signals
        if let signals = response.signals {
            for sig in signals.prefix(8) {
                let validTypes = ["risk", "alert", "opportunity", "change", "contradiction",
                                  "pattern", "doubt", "new_project", "emerging_problem"]
                guard validTypes.contains(sig.type) else { continue }

                var payload: [String: Any] = ["type": sig.type]
                if let related = sig.related_item_titles { payload["related_item_ids"] = related }
                let payloadJSON: String?
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let json = String(data: data, encoding: .utf8) { payloadJSON = json }
                else { payloadJSON = nil }

                let suggestion = AgentSuggestion(
                    projectID: project.id,
                    type: sig.type,
                    title: sig.title,
                    body: sig.body,
                    status: "visible",
                    sourceItemID: newItem.id,
                    payloadJSON: payloadJSON,
                    impactScore: sig.impact,
                    urgencyScore: sig.urgency
                )
                context.insert(suggestion)
            }
            try? context.save()
        }

        // Project summary update — use snapshot to avoid race condition
        let contribution = response.project_summary_contribution ?? response.project_summary_update ?? ""
        if !contribution.isEmpty {
            let auth = FieldAuthorityService.shared
            if auth.canModify(field: "summary", of: project, by: .llm) {
                let datePrefix = Date().formatted(date: .abbreviated, time: .omitted)
                let entry = "\n\n[\(datePrefix) — from \"\(newItem.title)\"]\n\(contribution)"
                let newSummary = (project.summary ?? "") + entry
                _ = try? ProjectService(context: context).update(
                    id: project.id,
                    fields: ProjectUpdateFields(summary: newSummary),
                    origin: .llm
                )
            } else {
                let sugSvc = SuggestionGatingService(context: context)
                sugSvc.proposeChange(
                    field: "summary",
                    proposedValue: contribution,
                    on: project.name,
                    projectID: project.id,
                    sourceItemID: newItem.id,
                    reason: "New item \"\(newItem.title)\" contributes this summary"
                )
            }
        } else {
            AppLog.provider.warning("ProjectIngestion: no summary contribution in AI response")
        }

        // Auto-snapshot after ingestion
        VersioningService.shared.createSnapshot(projectID: project.id,
            label: "Ingestion: \"\(newItem.title)\"",
            trigger: .auto_ingestion, context: context)
    }

    // MARK: - Fuzzy matching (exact match first, then word-boundary)

    private func findItem(byTitle title: String, in items: [KnowledgeItem]) -> KnowledgeItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact match first
        if let exact = items.first(where: { $0.title.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        // Word boundary: match only if the title appears as a whole word
        let lower = trimmed.lowercased()
        return items.first { item in
            let itemLower = item.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // Require at least 2 chars to avoid single-char false positives
            // while still matching short acronyms like "AI", "UI", "iOS"
            guard lower.count >= 2 else { return false }
            return itemLower.contains(lower)
        }
    }

    private func findTask(byTitle title: String, in tasks: [TaskItem]) -> TaskItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = tasks.first(where: { $0.title.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        let lower = trimmed.lowercased()
        return tasks.first { task in
            let taskLower = task.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard lower.count >= 4 else { return false }
            return taskLower.contains(lower)
        }
    }

    private func edgeType(from string: String) -> EdgeType {
        EdgeType(rawValue: string) ?? .relatesTo
    }

    // MARK: - Helpers

    private func parseIngestionJSON(_ rawContent: String) -> IngestionResponse? {
        let cleaned = ProviderAdapter.normalizeJSON(rawContent)
        guard let data = cleaned.data(using: .utf8) else {
            AppLog.provider.error("ProjectIngestion: failed to convert cleaned JSON to data")
            return nil
        }
        do {
            let response = try JSONDecoder().decode(IngestionResponse.self, from: data)
            AppLog.provider.info("ProjectIngestion: decoded — \(response.connections?.count ?? 0) connections, \(response.new_tasks?.count ?? 0) new tasks")
            return response
        } catch {
            AppLog.provider.error("ProjectIngestion: JSON decode failed: \(error). Raw: \(String(rawContent.prefix(300)))")
            return nil
        }
    }

    private func saveRawIngestionResponse(_ content: String, itemID: UUID, label: String) {
        try? fileStore.createMeetingDirectory(for: itemID)
        try? content.data(using: .utf8)?.write(to: fileStore.itemDirectoryURL(for: itemID).appendingPathComponent("project.ingestion.\(label).txt"))
    }

    private func sendWithRetry(provider: any AIProvider, request: AIRequest, maxRetries: Int) async throws -> AIResponse {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await provider.send(request)
            } catch let error as ProviderError {
                lastError = error
                let retryable: Bool = {
                    switch error {
                    case .apiError(let code, _): return code >= 500 || code == 429
                    case .timeout, .networkUnavailable: return true
                    default: return false
                    }
                }()
                if retryable && attempt < maxRetries {
                    let delay = Double(1 << attempt)
                    AppLog.provider.warning("ProjectIngestion: retrying after \(delay)s (attempt \(attempt + 1)/\(maxRetries), \(error))")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delay = Double(1 << attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? ProviderError.requestFailed(statusCode: 0)
    }
}

// MARK: - SuggestionGatingService

/// Converts blocked LLM write attempts into AgentSuggestions for user review.
@MainActor
final class SuggestionGatingService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func proposeChange(
        field: String,
        proposedValue: String,
        on itemTitle: String,
        projectID: UUID?,
        sourceItemID: UUID? = nil,
        reason: String? = nil,
        confidence: Double = 0.7
    ) {
        let truncated = String(proposedValue.prefix(200))
        let payload: [String: String] = [
            "field": field,
            "proposedValue": truncated,
            "reason": reason ?? "AI suggested this change"
        ]
        let payloadJSON: String?
        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            payloadJSON = json
        } else {
            payloadJSON = nil
        }

        let suggestion = AgentSuggestion(
            projectID: projectID,
            type: "field_change",
            title: "Change \(field) on \"\(itemTitle)\"",
            body: "Proposed: set \(field) to \"\(truncated)\". Reason: \(reason ?? "AI analysis")",
            status: "visible",
            confidence: confidence,
            sourceItemID: sourceItemID,
            payloadJSON: payloadJSON
        )
        context.insert(suggestion)
        try? context.save()
    }

    func proposeTaskUpdate(
        taskTitle: String,
        field: String,
        proposedValue: String,
        projectID: UUID?,
        sourceItemID: UUID? = nil,
        reason: String? = nil
    ) {
        proposeChange(
            field: "task.\(field)",
            proposedValue: proposedValue,
            on: taskTitle,
            projectID: projectID,
            sourceItemID: sourceItemID,
            reason: reason
        )
    }
}
