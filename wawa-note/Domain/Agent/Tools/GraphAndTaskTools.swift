import Foundation

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

        return ToolResult(content: "Note created successfully.\nTitle: \(item.title)\nUUID: \(item.id.uuidString)\nType: note\nUse get_item with this UUID to read it.", citations: [ChatCitation(itemId: item.id, title: item.title, snippet: title, itemType: "note")], isError: false, displaySummary: "Created note: \(title)")
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
