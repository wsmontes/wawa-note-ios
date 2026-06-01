import Foundation
import SwiftData

// MARK: - Get Connections

struct GetConnectionsTool: AgentTool {
    let name = "get_connections"
    let description = "Get graph connections for an item — outgoing edges (what this item references, mentions, produced) and incoming edges (what references this). Shows edge types and weights."
    let parameters = AIToolParameters(properties: ["item_id": AIToolProperty(type: "string", description: "Full UUID of the item")], required: ["item_id"])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let idStr = arguments["item_id"] as? String, let iid = UUID(uuidString: idStr) else {
            return ToolFormatting.error(tool: name, reason: "Missing or invalid 'item_id'.", fix: "Provide a full valid UUID from search or list results.")
        }
        let es = GraphEdgeService(context: context.modelContext)
        let outgoing = (try? es.edges(from: iid)) ?? []
        let incoming = (try? es.edges(to: iid)) ?? []

        if outgoing.isEmpty && incoming.isEmpty {
            return ToolResult(content: "No connections found for item \(idStr). This item has no graph edges.", citations: [], isError: false, displaySummary: "connections: none")
        }

        var content = "Connections for item \(idStr):\n\n"
        if !outgoing.isEmpty {
            content += "**Outgoing (\(outgoing.count)):**\n"
            for e in outgoing.prefix(20) {
                content += "- \(e.edgeType.rawValue) → target UUID: \(e.toID.uuidString) (weight: \(String(format: "%.2f", e.weight)))\n"
            }
            if outgoing.count > 20 { content += "... +\(outgoing.count - 20) more. Use get_item to explore specific targets.\n" }
            content += "\n"
        }
        if !incoming.isEmpty {
            content += "**Incoming (\(incoming.count)):**\n"
            for e in incoming.prefix(20) {
                content += "- \(e.edgeType.rawValue) ← source UUID: \(e.fromID.uuidString) (weight: \(String(format: "%.2f", e.weight)))\n"
            }
            if incoming.count > 20 { content += "... +\(incoming.count - 20) more.\n" }
        }
        content += "\nUse get_item with these UUIDs to read the connected items."

        return ToolFormatting.success(summary: "connections: \(outgoing.count + incoming.count) edges", content: content, citations: [], totalFound: outgoing.count + incoming.count, shown: min(outgoing.count, 20) + min(incoming.count, 20))
    }
}

// MARK: - Get Tasks

struct GetTasksTool: AgentTool {
    let name = "get_tasks"
    let description = "List tasks filtered by project, status, or owner. Returns task details with source provenance UUIDs."
    let parameters = AIToolParameters(properties: [
        "project_id": AIToolProperty(type: "string", description: "Project UUID (optional)"),
        "status": AIToolProperty(type: "string", description: "todo, inProgress, done, cancelled"),
        "limit": AIToolProperty(type: "integer", description: "Max results (default 20)")
    ], required: [])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let ts = TaskService(context: context.modelContext)
        let limit = min((arguments["limit"] as? Int) ?? 20, 40)

        var tasks: [TaskItem] = []
        if let pidStr = arguments["project_id"] as? String, let pid = UUID(uuidString: pidStr) {
            tasks = (try? ts.tasks(for: pid)) ?? []
        } else if let s = arguments["status"] as? String {
            guard let st = TaskStatus(rawValue: s) else {
                return ToolFormatting.error(tool: name, reason: "Invalid status '\(s)'.", fix: "Use: todo, inProgress, done, cancelled")
            }
            tasks = (try? ts.tasksByStatus(st)) ?? []
        } else {
            return ToolResult(content: "Specify project_id or status to filter tasks. Examples:\n- get_tasks(project_id: \"UUID\") for project tasks\n- get_tasks(status: \"todo\") for open tasks\n- get_tasks(status: \"inProgress\") for active tasks", citations: [], isError: false, displaySummary: "tasks: need filter")
        }

        let result = Array(tasks.prefix(limit))
        if result.isEmpty {
            return ToolResult(content: "No tasks found with the given filters.", citations: [], isError: false, displaySummary: "tasks: 0 results")
        }

        var content = "Found \(result.count) tasks:\n\n"
        for (idx, t) in result.enumerated() {
            content += ToolFormatting.formatTaskLine(t, index: idx + 1) + "\n"
        }

        return ToolFormatting.success(summary: "tasks: \(result.count)", content: content, citations: [], totalFound: tasks.count, shown: result.count)
    }
}

// MARK: - Create Note

struct CreateNoteTool: AgentTool {
    let name = "create_note"
    let description = "Create a new note in the knowledge base. The note appears in the inbox."
    let parameters = AIToolParameters(properties: [
        "title": AIToolProperty(type: "string", description: "Note title"),
        "body_text": AIToolProperty(type: "string", description: "Content in Markdown (optional)")
    ], required: ["title"])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let title = (arguments["title"] as? String) ?? "Untitled"
        let body = arguments["body_text"] as? String
        let svc = KnowledgeItemService(context: context.modelContext)

        guard let item = try? svc.createItem(type: .note, title: title, bodyText: body) else {
            return ToolFormatting.error(tool: name, reason: "Failed to create note.", fix: "Check that the knowledge base is accessible and try again.")
        }

        return ToolResult(content: "Note created successfully.\nTitle: \(item.title)\nUUID: \(item.id.uuidString)\nType: note\nUse get_item with this UUID to read it.", citations: [ChatCitation(itemId: item.id, title: item.title, snippet: title, itemType: .note)], isError: false, displaySummary: "Created note: \(title)")
    }
}

// MARK: - Create Task

struct CreateTaskTool: AgentTool {
    let name = "create_task"
    let description = "Create a new task, optionally linked to a project."
    let parameters = AIToolParameters(properties: [
        "title": AIToolProperty(type: "string", description: "Task title"),
        "project_id": AIToolProperty(type: "string", description: "Project UUID (optional)"),
        "priority": AIToolProperty(type: "string", description: "low, medium, high, critical (default: medium)"),
        "owner_name": AIToolProperty(type: "string", description: "Who is responsible (optional)")
    ], required: ["title"])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let title = (arguments["title"] as? String) ?? "Untitled Task"
        let pid = (arguments["project_id"] as? String).flatMap(UUID.init(uuidString:))
        let priority = (arguments["priority"] as? String).flatMap(TaskPriority.init(rawValue:)) ?? .medium
        let owner = arguments["owner_name"] as? String
        let ts = TaskService(context: context.modelContext)

        guard let task = try? ts.create(title: title, projectID: pid, priority: priority, ownerName: owner) else {
            return ToolFormatting.error(tool: name, reason: "Failed to create task.", fix: "Verify the project exists and try again.")
        }

        var content = "Task created successfully.\nTitle: \(task.title)\nPriority: \(priority.rawValue)\nStatus: \(task.statusRaw)"
        if let o = owner { content += "\nOwner: \(o)" }
        if let p = pid { content += "\nProject UUID: \(p.uuidString)" }
        return ToolResult(content: content, citations: [], isError: false, displaySummary: "Created task: \(title)")
    }
}

// MARK: - Summarize Day

struct SummarizeDayTool: AgentTool {
    let name = "summarize_day"
    let description = "Summarize all activity on a specific date — items created, meetings recorded, notes written."
    let parameters = AIToolParameters(properties: ["date": AIToolProperty(type: "string", description: "ISO 8601 date (YYYY-MM-DD)")], required: ["date"])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let dateStr = arguments["date"] as? String else {
            return ToolFormatting.error(tool: name, reason: "Missing 'date' parameter.", fix: "Provide a date in ISO 8601 format: YYYY-MM-DD")
        }
        guard let date = ISO8601DateFormatter().date(from: dateStr + "T00:00:00Z") else {
            return ToolFormatting.error(tool: name, reason: "Invalid date format '\(dateStr)'.", fix: "Use ISO 8601 format: YYYY-MM-DD (e.g., 2026-05-28)")
        }
        let svc = KnowledgeItemService(context: context.modelContext)
        let items = (try? svc.allItems()) ?? []
        let cal = Calendar.current
        let dayItems = items.filter { cal.isDate($0.createdAt, inSameDayAs: date) }

        if dayItems.isEmpty {
            return ToolResult(content: "No activity on \(dateStr). This day has no items in the knowledge base.", citations: [], isError: false, displaySummary: "No activity on \(dateStr)")
        }

        var content = "Activity on \(dateStr) — \(dayItems.count) items:\n\n"
        for (idx, item) in dayItems.enumerated() {
            content += ToolFormatting.formatItemLine(item, index: idx + 1) + "\n"
        }
        content += "Use get_item with any UUID to read the full item."

        return ToolFormatting.success(summary: "Day: \(dayItems.count) items on \(dateStr)", content: content, citations: [], totalFound: dayItems.count, shown: dayItems.count)
    }
}

// MARK: - Get Project

struct GetProjectTool: AgentTool {
    let name = "get_project"
    let description = "Fetch a project with its tasks, status, and summary."
    let parameters = AIToolParameters(properties: ["project_id": AIToolProperty(type: "string", description: "Project UUID")], required: ["project_id"])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let idStr = arguments["project_id"] as? String, let pid = UUID(uuidString: idStr) else {
            return ToolFormatting.error(tool: name, reason: "Missing or invalid 'project_id'.", fix: "Provide a valid project UUID.")
        }
        let ps = ProjectService(context: context.modelContext)
        let ts = TaskService(context: context.modelContext)
        guard let project = try ps.fetch(id: pid) else {
            return ToolFormatting.error(tool: name, reason: "No project found with UUID \(idStr).", fix: "Use search_knowledge to find project-related items, then check their connections.")
        }
        let allTasks = (try? ts.tasks(for: pid)) ?? []
        let tasks = allTasks.prefix(20)

        var content = "## \(project.name)\nStatus: \(project.statusRaw) | Created: \(project.createdAt.formatted(date: .abbreviated, time: .omitted))\n"
        if let s = project.summary, !s.isEmpty { content += "\n\(s)\n" }
        content += "\n### Tasks (\(allTasks.count) total"

        if allTasks.count > 20 { content += ", showing first 20" }
        content += ")\n"
        for (idx, t) in tasks.enumerated() { content += ToolFormatting.formatTaskLine(t, index: idx + 1) + "\n" }

        return ToolFormatting.success(summary: "Project: \(project.name) (\(allTasks.count) tasks)", content: content, citations: [], totalFound: allTasks.count, shown: tasks.count)
    }
}

// MARK: - Update Task Tool

struct UpdateTaskTool: AgentTool {
    let name = "update_task"
    let description = "Update a task's status, priority, owner, or due date. Provide the task title and only the fields you want to change."
    let parameters = AIToolParameters(properties: [
        "task_title": AIToolProperty(type: "string", description: "Exact title of the task to update", enum: nil),
        "new_status": AIToolProperty(type: "string", description: "todo|inProgress|done|cancelled", enum: nil),
        "new_priority": AIToolProperty(type: "string", description: "low|medium|high|critical", enum: nil),
        "new_due_date": AIToolProperty(type: "string", description: "ISO 8601 date", enum: nil)
    ], required: ["task_title"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let title = args["task_title"] as? String else { return ToolResult(content: "Missing task_title", citations: [], isError: true, displaySummary: "Error") }
        let taskSvc = TaskService(context: context.modelContext)
        let tasks: [TaskItem] = {
            if let pid = context.activeProjectID { return (try? taskSvc.tasks(for: pid)) ?? [] }
            return (try? context.modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
        }()
        guard let task = tasks.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) else {
            return ToolResult(content: "Task not found: \(title)", citations: [], isError: true, displaySummary: "Not found")
        }
        if let s = args["new_status"] as? String, let st = TaskStatus(rawValue: s) { try? taskSvc.updateStatus(task, to: st) }
        if let p = args["new_priority"] as? String, let pr = TaskPriority(rawValue: p) { task.priority = pr }
        if let d = args["new_due_date"] as? String, let date = ISO8601DateFormatter().date(from: d) { task.dueAt = date }
        try? context.modelContext.save()
        return ToolResult(content: "Task updated: \(task.title)", citations: [], isError: false, displaySummary: "Updated: \(title)")
    }
}

// MARK: - Create Edge Tool

struct CreateEdgeTool: AgentTool {
    let name = "create_edge"
    let description = "Create a connection between two items. Types: supports, contradicts, references, relates_to."
    let parameters = AIToolParameters(properties: [
        "from_title": AIToolProperty(type: "string", description: "Title of the source item", enum: nil),
        "to_title": AIToolProperty(type: "string", description: "Title of the target item", enum: nil),
        "type": AIToolProperty(type: "string", description: "supports|contradicts|references|relates_to", enum: nil)
    ], required: ["from_title", "to_title", "type"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let fromTitle = args["from_title"] as? String,
              let toTitle = args["to_title"] as? String,
              let typeStr = args["type"] as? String else {
            return ToolResult(content: "Missing required arguments", citations: [], isError: true, displaySummary: "Error")
        }
        let svc = KnowledgeItemService(context: context.modelContext)
        let items = (try? svc.allItems()) ?? []
        guard let from = items.first(where: { $0.title.localizedCaseInsensitiveCompare(fromTitle) == .orderedSame }),
              let to = items.first(where: { $0.title.localizedCaseInsensitiveCompare(toTitle) == .orderedSame }) else {
            return ToolResult(content: "Could not find both items", citations: [], isError: true, displaySummary: "Not found")
        }
        let edgeSvc = GraphEdgeService(context: context.modelContext)
        let et = EdgeType(rawValue: typeStr) ?? .relatesTo
        try edgeSvc.create(fromID: from.id, toID: to.id, edgeType: et, provenanceItemID: from.id)
        return ToolResult(content: "Edge created: \(from.title) → [\(et.rawValue)] → \(to.title)", citations: [], isError: false, displaySummary: "Connected: \(from.title) → \(to.title)")
    }
}

// MARK: - Set Annotation Tool

struct SetAnnotationTool: AgentTool {
    let name = "set_annotation"
    let description = "Add or update a key-value annotation on an item."
    let parameters = AIToolParameters(properties: [
        "item_title": AIToolProperty(type: "string", description: "Title of the item", enum: nil),
        "key": AIToolProperty(type: "string", description: "Annotation key", enum: nil),
        "value": AIToolProperty(type: "string", description: "Annotation value", enum: nil)
    ], required: ["item_title", "key", "value"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let title = args["item_title"] as? String,
              let key = args["key"] as? String,
              let value = args["value"] as? String else {
            return ToolResult(content: "Missing arguments", citations: [], isError: true, displaySummary: "Error")
        }
        let items = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
        guard let item = items.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) else {
            return ToolResult(content: "Item not found: \(title)", citations: [], isError: true, displaySummary: "Not found")
        }
        let annotation = Annotation(source: "agent", key: key, value: value, itemID: item.id)
        context.modelContext.insert(annotation)
        try context.modelContext.save()
        return ToolResult(content: "Annotation set: \(key) = \(value)", citations: [], isError: false, displaySummary: "Annotated: \(key)")
    }
}

// MARK: - Trash Item Tool

struct TrashItemTool: AgentTool {
    let name = "trash_item"
    let description = "Move an item to the trash. Does not destroy the original audio or image."
    let parameters = AIToolParameters(properties: [
        "item_title": AIToolProperty(type: "string", description: "Title of the item to trash", enum: nil)
    ], required: ["item_title"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let title = args["item_title"] as? String else { return ToolResult(content: "Missing item_title", citations: [], isError: true, displaySummary: "Error") }
        let items = (try? KnowledgeItemService(context: context.modelContext).allItems()) ?? []
        guard let item = items.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) else {
            return ToolResult(content: "Item not found: \(title)", citations: [], isError: true, displaySummary: "Not found")
        }
        try TrashService(context: context.modelContext).moveToTrash(item)
        return ToolResult(content: "Trashed: \(item.title)", citations: [], isError: false, displaySummary: "Trashed: \(title)")
    }
}

// MARK: - Get Analysis Tool

struct GetAnalysisTool: AgentTool {
    let name = "get_analysis"
    let description = "Get the full analysis (summary, decisions, actions, risks, entities) for an item."
    let parameters = AIToolParameters(properties: [
        "item_id": AIToolProperty(type: "string", description: "UUID of the item", enum: nil)
    ], required: ["item_id"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let idStr = args["item_id"] as? String, let id = UUID(uuidString: idStr) else { return ToolResult(content: "Invalid UUID", citations: [], isError: true, displaySummary: "Error") }
        let svc = KnowledgeItemService(context: context.modelContext)
        guard let item = try? svc.fetchItem(id: id) else { return ToolResult(content: "Item not found", citations: [], isError: true, displaySummary: "Not found") }

        // Try MeetingAnalysis first, then DynamicAnalysis
        if let analysis = try? context.fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: id) {
            var content = "## Analysis: \(item.title)\nSummary: \(analysis.shortSummary)\n"
            if !analysis.decisions.isEmpty { content += "\nDecisions:\n" + analysis.decisions.map { "- \($0.title)" }.joined(separator: "\n") }
            if !analysis.actionItems.isEmpty { content += "\nActions:\n" + analysis.actionItems.map { "- \($0.task)" }.joined(separator: "\n") }
            if !analysis.risks.isEmpty { content += "\nRisks:\n" + analysis.risks.map { "- \($0.risk)" }.joined(separator: "\n") }
            return ToolFormatting.success(summary: "Analysis: \(item.title)", content: content, citations: [ChatCitation(itemId: item.id, title: item.title, snippet: analysis.shortSummary, itemType: item.type)], totalFound: 1, shown: 1)
        }
        return ToolResult(content: "No analysis found for item \(item.title)", citations: [], isError: true, displaySummary: "No analysis")
    }
}

// MARK: - Think Tool (Advisor Escalation)

struct ThinkTool: AgentTool {
    let name = "think"
    let description = "Ask a more capable reasoning model for help with complex analysis. Use for comparing items, finding patterns, or multi-step reasoning. Provide structured context, not raw data."
    let parameters = AIToolParameters(properties: [
        "question": AIToolProperty(type: "string", description: "Focused question requiring complex reasoning", enum: nil),
        "context": AIToolProperty(type: "string", description: "Structured data to reason about (not raw transcripts)", enum: nil)
    ], required: ["question", "context"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        // The AgentLoop routes think calls to the advisor model automatically.
        // This tool's execute is a no-op — the real work happens in the LLM's response.
        // We just return the context so the advisor can work with it.
        let question = args["question"] as? String ?? ""
        let ctx = args["context"] as? String ?? ""
        return ToolResult(content: "Think requested:\n\(question)\n\nContext:\n\(ctx.prefix(2000))", citations: [], isError: false, displaySummary: "Asking advisor...")
    }
}
