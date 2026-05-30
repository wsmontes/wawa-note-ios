import Foundation
import SwiftData
import OSLog

@MainActor
final class ProjectIngestionPipeline {
    static let shared = ProjectIngestionPipeline()

    private init() {}

    func ingest(itemID: UUID, projectID: UUID, using modelContext: ModelContext) async {
        await runIngestion(itemID: itemID, projectID: projectID, context: modelContext)
    }

    // MARK: - Private

    private func runIngestion(itemID: UUID, projectID: UUID, context: ModelContext) async {
        AppLog.provider.info("ProjectIngestion: starting for item \(itemID) → project \(projectID)")

        guard let provider = try? ProviderRouter.resolveActive(context: context) else {
            AppLog.provider.error("ProjectIngestion: NO AI PROVIDER configured. Cannot enrich project \(projectID). Go to Settings to add one.")
            return
        }

        let projSvc = ProjectService(context: context)
        let knowledgeSvc = KnowledgeItemService(context: context)
        let taskSvc = TaskService(context: context)
        let edgeSvc = GraphEdgeService(context: context)
        let fileStore = FileArtifactStore()

        guard let project = try? projSvc.fetch(id: projectID),
              let newItem = try? knowledgeSvc.fetchItem(id: itemID) else {
            AppLog.provider.error("ProjectIngestion: project \(projectID) or item \(itemID) NOT FOUND in SwiftData")
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
        let config = AIConfigService.shared
        let preset = config.presetFor(model: model)
        let isReasoning = preset?.reasoningModel ?? false
        let maxOut = preset?.maxOutputTokens ?? 4096

        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(prompt)])
            ],
            temperature: isReasoning ? nil : 0.3,
            maxTokens: min(maxOut / 2, 4000),
            responseFormat: .jsonObject
        )

        do {
            let response = try await sendWithRetry(provider: provider, request: request, maxRetries: 3)
            let rawContent = response.content
            AppLog.provider.info("ProjectIngestion: raw response (\(rawContent.count) chars): \(String(rawContent.prefix(500)))")

            if let json = parseIngestionJSON(rawContent) {
                applyResults(json: json, newItem: newItem, project: project, allItems: allItems,
                            existingTasks: existingTasks, edgeSvc: edgeSvc, taskSvc: taskSvc, context: context)
                AppLog.provider.info("ProjectIngestion: SUCCESS — \(json["new_tasks"] as? [[String: Any]] ?? []).count new tasks, \(json["connections"] as? [[String: Any]] ?? []).count connections for project \(project.name)")
                return
            }

            // Attempt 2: retry with "fix your JSON" prompt
            saveRawIngestionResponse(rawContent, itemID: itemID, label: "raw")
            AppLog.provider.warning("ProjectIngestion: initial parse failed. Retrying with JSON fix prompt...")

            let fixPrompt = """
            Your previous response was not valid JSON. Here is what you returned:

            \(ProviderAdapter.normalizeJSON(rawContent).prefix(2000))

            Return ONLY valid JSON matching the original schema. No markdown, no code fences. The JSON must parse correctly.
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
                    applyResults(json: json, newItem: newItem, project: project, allItems: allItems,
                                existingTasks: existingTasks, edgeSvc: edgeSvc, taskSvc: taskSvc, context: context)
                    return
                }
            } catch {
                AppLog.provider.error("ProjectIngestion: JSON fix retry failed: \(error)")
            }

            AppLog.provider.error("ProjectIngestion: all parse attempts failed for item \(itemID)")
        } catch {
            AppLog.provider.error("ProjectIngestion: AI call failed after retries: \(error)")
        }
    }

    // MARK: - System Prompt

    private var systemPrompt: String {
        """
        You are a project knowledge analyst. You analyze how a new item relates to a project.

        KEY PRINCIPLES:
        - A new item does NOT make you rethink the entire project. It ADDS to existing knowledge.
        - Read the new item THROUGH the project's eyes: how does it fit, connect, extend?
        - Read the project THROUGH the new item's eyes: what does it reveal, confirm, or change?
        - NEVER suggest deleting tasks or connections. Tasks can change status (done/cancelled). Connections can be added.
        - Be conservative. Only report what is clearly supported. Flag uncertainty.

        Return JSON with these fields:
        {
          "item_project_view": "one sentence: how this item fits into the project's existing knowledge",
          "project_item_view": "one sentence: what this item reveals about the project that was not clear before",
          "connections": [{"from_title": "...", "to_title": "...", "type": "supports|contradicts|references|extends|relates_to", "explanation": "..."}],
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
        Reading the project with the knowledge from this item — what becomes clearer? What was uncertain that is now confirmed? What assumptions should be revisited?

        Return JSON as specified in the system prompt.
        """
    }

    // MARK: - Apply results

    private func applyResults(
        json: [String: Any],
        newItem: KnowledgeItem,
        project: Project,
        allItems: [KnowledgeItem],
        existingTasks: [TaskItem],
        edgeSvc: GraphEdgeService,
        taskSvc: TaskService,
        context: ModelContext
    ) {
        // --- Task status updates (never delete) ---
        if let updates = json["task_updates"] as? [[String: Any]] {
            for update in updates {
                guard let title = update["task_title"] as? String,
                      let newStatusRaw = update["new_status"] as? String else { continue }
                if let task = findTask(byTitle: title, in: existingTasks),
                   let newStatus = TaskStatus(rawValue: newStatusRaw) {
                    try? taskSvc.updateStatus(task, to: newStatus)
                }
            }
        }

        // --- New tasks ---
        if let newTasks = json["new_tasks"] as? [[String: Any]] {
            for t in newTasks.prefix(3) {
                guard let title = t["title"] as? String else { continue }
                let priority = (t["priority"] as? String).flatMap(TaskPriority.init(rawValue:)) ?? .medium
                try? taskSvc.create(title: title, projectID: project.id, priority: priority, sourceItemID: newItem.id)
            }
        }

        // --- New connections ---
        if let connections = json["connections"] as? [[String: Any]] {
            for conn in connections.prefix(5) {
                guard let fromTitle = conn["from_title"] as? String,
                      let toTitle = conn["to_title"] as? String,
                      let typeStr = conn["type"] as? String else { continue }

                let fromItem = findItem(byTitle: fromTitle, in: allItems) ?? newItem
                let toItem = findItem(byTitle: toTitle, in: allItems)
                guard let toItem else { continue }

                let edgeType = edgeType(from: typeStr)
                try? edgeSvc.create(fromID: fromItem.id, toID: toItem.id, edgeType: edgeType, provenanceItemID: newItem.id)
            }
        }

        // --- Edge reinforcements (confirmed connections) ---
        if let reinforcements = json["edge_reinforcements"] as? [[String: Any]], !reinforcements.isEmpty {
            AppLog.provider.info("ProjectIngestion: \(reinforcements.count) edge reinforcements confirmed")
        }

        // --- Insights ---
        if let insights = json["insights"] as? [[String: Any]], !insights.isEmpty {
            AppLog.provider.info("ProjectIngestion: \(insights.count) insights received")
        }

        // --- Project summary update ---
        let contribution = (json["project_summary_contribution"] as? String) ?? (json["project_summary_update"] as? String) ?? ""
        if !contribution.isEmpty {
            let datePrefix = Date().formatted(date: .abbreviated, time: .omitted)
            let entry = "\n\n[\(datePrefix) — from \"\(newItem.title)\"]\n\(contribution)"
            project.summary = (project.summary ?? "") + entry
            do { try context.save() }
            catch { AppLog.provider.error("ProjectIngestion: failed to save summary: \(error.localizedDescription)") }
        } else {
            AppLog.provider.warning("ProjectIngestion: no summary contribution in AI response. Keys present: \(json.keys.sorted().joined(separator: ", "))")
        }
    }

    private func findItem(byTitle title: String, in items: [KnowledgeItem]) -> KnowledgeItem? {
        ItemContextBuilder.findItem(byTitle: title, in: items)
    }

    private func findTask(byTitle title: String, in tasks: [TaskItem]) -> TaskItem? {
        ItemContextBuilder.findTask(byTitle: title, in: tasks)
    }

    private func edgeType(from string: String) -> EdgeType {
        switch string {
        case "supports": return .supports
        case "contradicts": return .contradicts
        case "references": return .references
        case "extends": return .relatesTo
        default: return .relatesTo
        }
    }

    // MARK: - Helpers

    private func parseIngestionJSON(_ rawContent: String) -> [String: Any]? {
        let cleaned = ProviderAdapter.normalizeJSON(rawContent)
        guard let data = cleaned.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            AppLog.provider.error("ProjectIngestion: JSON parse failed. Raw: \(String(rawContent.prefix(300)))")
            return nil
        }
        AppLog.provider.info("ProjectIngestion: parsed JSON with keys: \(json.keys.sorted().joined(separator: ", "))")
        return json
    }

    private func saveRawIngestionResponse(_ content: String, itemID: UUID, label: String) {
        let fs = FileArtifactStore()
        try? fs.createMeetingDirectory(for: itemID)
        try? content.data(using: .utf8)?.write(to: fs.itemDirectoryURL(for: itemID).appendingPathComponent("project.ingestion.\(label).txt"))
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
