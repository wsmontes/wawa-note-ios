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

// MARK: - Pipeline

@MainActor
final class ProjectIngestionPipeline: ObservableObject {
    private let ingestionState: ProjectIngestionState
    private let fileStore: FileArtifactStore

    init(ingestionState: ProjectIngestionState, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.ingestionState = ingestionState
        self.fileStore = fileStore
    }

    func ingest(itemID: UUID, projectID: UUID, using modelContext: ModelContext) async {
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

        // 2. Prompt: dual-perspective analysis
        let prompt = buildIngestionPrompt(projectContext: projectContext, newItemContext: itemContext)
        let model = AutomationSettings.shared.resolveAutoAnalysisModel(context: context) ?? AutomationSettings.shared.autoAnalysisModel
        let params = AIConfigService.shared.requestParams(for: "project_ingestion", model: model)

        // Snapshot summary before AI call to avoid race condition on read-modify-write
        let previousSummary = project.summary ?? ""

        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(buildSystemPrompt(for: project))]),
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
                            context: context, previousSummary: previousSummary)
                AppLog.provider.info("ProjectIngestion: SUCCESS — \(json.new_tasks?.count ?? 0) new tasks, \(json.connections?.count ?? 0) connections for project \(project.name)")
                postIngestionCompleted(itemID: itemID, projectID: projectID)
                return
            }

            // JSON fix retry: include original schema context so model knows target format
            saveRawIngestionResponse(rawContent, itemID: itemID, label: "raw")
            AppLog.provider.warning("ProjectIngestion: initial parse failed. Retrying with JSON fix prompt...")

            let fixPrompt = """
            Original task: \(prompt.prefix(1000))...

            Your previous response was not valid JSON. Fix it to match this schema:

            {
              "connections": [{"from_title":"...","to_title":"...","type":"supports|contradicts|references|relates_to","explanation":"..."}],
              "task_updates": [{"task_title":"...","new_status":"done|cancelled","reason":"..."}],
              "new_tasks": [{"title":"...","priority":"low|medium|high","reason":"...","confidence":0.8}],
              "edge_reinforcements": [{"from_title":"...","to_title":"...","note":"..."}],
              "insights": [{"text":"...","confidence":0.8}],
              "project_summary_contribution": "..."
            }

            Your broken response: \(ProviderAdapter.normalizeJSON(rawContent).prefix(1500))

            Return ONLY valid JSON matching the schema. No markdown, no code fences.
            """

            let fixRequest = AIRequest(
                model: model,
                messages: [
                    AIMessage(role: .system, content: [.text("You are a JSON repair assistant. Output ONLY valid JSON matching the requested schema.")]),
                    AIMessage(role: .user, content: [.text(fixPrompt)])
                ],
                responseFormat: .jsonObject
            )

            do {
                let fixResponse = try await provider.send(fixRequest)
                saveRawIngestionResponse(fixResponse.content, itemID: itemID, label: "fix_attempt")
                if let json = parseIngestionJSON(fixResponse.content) {
                    AppLog.provider.info("ProjectIngestion: JSON fix retry succeeded")
                    applyResults(response: json, newItem: newItem, project: project, allItems: allItems,
                                existingTasks: existingTasks, edgeSvc: edgeSvc, taskSvc: taskSvc,
                                context: context, previousSummary: previousSummary)
                    postIngestionCompleted(itemID: itemID, projectID: projectID)
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

    private func postIngestionFailed(itemID: UUID, projectID: UUID, error: IngestionError) {
        ingestionState.setError(projectID, message: error.localizedDescription)
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(for project: Project) -> String {
        var prompt = """
        You are a project knowledge analyst. You analyze how a new item relates to a project.

        KEY PRINCIPLES:
        - A new item does NOT make you rethink the entire project. It ADDS to existing knowledge.
        - Read the new item THROUGH the project's eyes: how does it fit, connect, extend?
        - Read the project THROUGH the new item's eyes: what does it reveal, confirm, or change?
        - NEVER suggest deleting tasks or connections. Tasks can change status (done/cancelled). Connections can be added.
        - Be conservative. Only report what is clearly supported. Flag uncertainty.

        """

        if let instructions = project.customInstructions, !instructions.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += """
            PROJECT INSTRUCTIONS (from user):
            \(instructions)

            Use these instructions to guide your analysis. Prioritize what the user cares about.

            """
        }

        prompt += """
        Return JSON with these fields:
        {
          "item_project_view": "one sentence: how this item fits into the project's existing knowledge",
          "project_item_view": "one sentence: what this item reveals about the project that was not clear before",
          "connections": [{"from_title": "...", "to_title": "...", "type": "supports|contradicts|references|relates_to", "explanation": "..."}],
          "task_updates": [{"task_title": "...", "new_status": "done|cancelled", "reason": "..."}],
          "new_tasks": [{"title": "...", "priority": "low|medium|high", "reason": "..."}],
          "edge_reinforcements": [{"from_title": "...", "to_title": "...", "note": "this connection is confirmed by the new item"}],
          "insights": [{"text": "...", "confidence": 0.8}],
          "project_summary_contribution": "REQUIRED. One paragraph summarizing what new knowledge this item contributes to the project. Even if the item just confirms existing knowledge, state that. Never leave this field empty."
        }

        RULES:
        - project_summary_contribution is REQUIRED. Always return it, even if just one sentence.
        - task_updates: ONLY update status if the new item CLEARLY indicates a task is done or no longer relevant. Never delete.
        - connections: report genuine relationships. If a connection already exists, use edge_reinforcements instead to confirm it.
        - new_tasks: only tasks explicitly implied. Max 3.
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

    private func buildIngestionPrompt(projectContext: String, newItemContext: String) -> String {
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
        previousSummary: String
    ) {
        // Task status updates (never delete)
        if let updates = response.task_updates {
            for update in updates {
                if let task = findTask(byTitle: update.task_title, in: existingTasks),
                   let newStatus = TaskStatus(rawValue: update.new_status) {
                    try? taskSvc.updateStatus(task, to: newStatus)
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
                    sourceItemID: newItem.id, confidence: t.confidence
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

        // Project summary update — use snapshot to avoid race condition
        let contribution = response.project_summary_contribution ?? response.project_summary_update ?? ""
        if !contribution.isEmpty {
            let datePrefix = Date().formatted(date: .abbreviated, time: .omitted)
            let entry = "\n\n[\(datePrefix) — from \"\(newItem.title)\"]\n\(contribution)"
            project.summary = previousSummary + entry
            do { try context.save() }
            catch { AppLog.provider.error("ProjectIngestion: failed to save summary: \(error.localizedDescription)") }
        } else {
            AppLog.provider.warning("ProjectIngestion: no summary contribution in AI response")
        }
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
            // Require at least 4 chars to avoid false positives on short tokens like "ai", "a", "it"
            guard lower.count >= 4 else { return false }
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
        switch string {
        case "supports": return .supports
        case "contradicts": return .contradicts
        case "references": return .references
        case "extends", "relates_to": return .relatesTo
        default: return .relatesTo
        }
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
