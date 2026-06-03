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
    let description = "Summarize all activity on a specific date — items created, audio recorded, notes written."
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
    let description = "Create a typed connection between two items. Include source_segment_ids to link the edge to specific transcript segments or note paragraphs."
    let parameters = AIToolParameters(properties: [
        "from_title": AIToolProperty(type: "string", description: "Title of the source item", enum: nil),
        "to_title": AIToolProperty(type: "string", description: "Title of the target item", enum: nil),
        "type": AIToolProperty(type: "string", description: "supports|contradicts|references|relates_to|mentions|precedes|produces", enum: nil),
        "source_segment_ids": AIToolProperty(type: "array", description: "Optional segment IDs that prove this connection"),
        "confidence": AIToolProperty(type: "number", description: "Confidence 0.0-1.0 for this edge. AI-inferred edges should include this.")
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
        let segmentIDs = (args["source_segment_ids"] as? [String]) ?? []
        let conf = (args["confidence"] as? Double) ?? 0.5
        try edgeSvc.create(fromID: from.id, toID: to.id, edgeType: et, weight: conf,
            provenanceItemID: from.id, provenanceSegmentIDs: segmentIDs)
        let prov = segmentIDs.isEmpty ? "item-level" : "\(segmentIDs.count) segment(s)"
        return ToolResult(content: "Edge created: \(from.title) → [\(et.rawValue)] → \(to.title) (provenance: \(prov))", citations: [], isError: false, displaySummary: "Connected: \(from.title) → \(to.title)")
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
        // Fallback: check for DynamicAnalysis (framework-driven analysis)
        if let dynamic = try? context.fileStore.readArtifact(DynamicAnalysis.self, fileName: "analysis.json", meetingId: id) {
            var content = "## Analysis: \(item.title)\nSchema: \(dynamic.schemaId)\n"
            for key in dynamic.results.allKeys.prefix(20) {
                if let val = dynamic.results.stringField(key) {
                    content += "\n\(key): \(val.prefix(500))"
                }
            }
            return ToolFormatting.success(summary: "Dynamic Analysis: \(item.title)", content: String(content.prefix(3000)), citations: [ChatCitation(itemId: item.id, title: item.title, snippet: "Framework: \(dynamic.schemaId)", itemType: item.type)], totalFound: 1, shown: 1)
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

// MARK: - Framework Management Tools

struct CreateProjectFrameworkTool: AgentTool {
    let name = "create_project_framework"
    let description = "Generate a custom analysis framework for a project. Define what fields to extract from items, how to synthesize the project, and what views to show. Use this when creating a project for a specific domain (research, brainstorm, legal, etc.) that doesn't fit the default meeting/audio template."
    let parameters = AIToolParameters(properties: [
        "project_id": AIToolProperty(type: "string", description: "UUID of the project to configure", enum: nil),
        "domain_description": AIToolProperty(type: "string", description: "What kind of project is this? e.g. 'bird migration research', 'product launch', 'legal contract review'", enum: nil),
        "special_instructions": AIToolProperty(type: "string", description: "Any specific analysis preferences or focus areas", enum: nil)
    ], required: ["project_id", "domain_description"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let idStr = args["project_id"] as? String, let pid = UUID(uuidString: idStr) else {
            return ToolResult(content: "Missing or invalid project_id", citations: [], isError: true, displaySummary: "Error")
        }
        guard let domain = args["domain_description"] as? String else {
            return ToolResult(content: "Missing domain_description", citations: [], isError: true, displaySummary: "Error")
        }
        let instructions = args["special_instructions"] as? String ?? ""

        let projSvc = ProjectService(context: context.modelContext)
        guard let project = try? projSvc.fetch(id: pid) else {
            return ToolResult(content: "Project not found: \(idStr)", citations: [], isError: true, displaySummary: "Not found")
        }

        // Try to match a built-in framework based on domain keywords
        let lower = domain.lowercased()
        let fw: ProjectFramework
        if lower.contains("research") || lower.contains("study") || lower.contains("paper") || lower.contains("investigation") {
            fw = FrameworkService.researchFramework
        } else if lower.contains("brainstorm") || lower.contains("idea") || lower.contains("ideation") || lower.contains("creative") {
            fw = FrameworkService.brainstormFramework
        } else if lower.contains("journal") || lower.contains("diary") || lower.contains("personal") || lower.contains("reflection") {
            fw = FrameworkService.journalFramework
        } else {
            fw = FrameworkService.blankFramework
        }

        let svc = FrameworkService.shared
        svc.apply(to: project, framework: fw)
        try? context.modelContext.save()

        let views = fw.views.map(\.title).joined(separator: ", ")
        return ToolResult(content: "Framework applied to project '\(project.name)': \(fw.name)\nViews: \(views)\nIf this doesn't fit, use update_project_framework to customize.", citations: [], isError: false, displaySummary: "Framework: \(fw.name)")
    }
}

struct UpdateProjectFrameworkTool: AgentTool {
    let name = "update_project_framework"
    let description = "Update the analysis framework for a project. Switch to a different built-in framework or provide a custom JSON framework definition."
    let parameters = AIToolParameters(properties: [
        "project_id": AIToolProperty(type: "string", description: "UUID of the project", enum: nil),
        "framework_id": AIToolProperty(type: "string", description: "Built-in framework ID: builtin/meeting, builtin/research, builtin/brainstorm, builtin/journal, builtin/blank", enum: nil),
        "framework_json": AIToolProperty(type: "string", description: "Custom framework JSON definition (advanced)", enum: nil)
    ], required: ["project_id"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let idStr = args["project_id"] as? String, let pid = UUID(uuidString: idStr) else {
            return ToolResult(content: "Missing or invalid project_id", citations: [], isError: true, displaySummary: "Error")
        }
        let projSvc = ProjectService(context: context.modelContext)
        guard let project = try? projSvc.fetch(id: pid) else {
            return ToolResult(content: "Project not found: \(idStr)", citations: [], isError: true, displaySummary: "Not found")
        }

        // Try custom JSON first, then built-in ID, then error
        if let json = args["framework_json"] as? String {
            let svc = FrameworkService.shared
            switch svc.validate(json) {
            case .success(let fw):
                svc.apply(to: project, framework: fw)
                try? context.modelContext.save()
                return ToolResult(content: "Custom framework applied to '\(project.name)'.", citations: [], isError: false, displaySummary: "Framework updated")
            case .failure(let e):
                return ToolResult(content: "Invalid framework JSON: \(e.localizedDescription)", citations: [], isError: true, displaySummary: "Invalid JSON")
            }
        }

        if let fwId = args["framework_id"] as? String {
            let fw: ProjectFramework
            switch fwId {
            case "builtin/meeting": fw = FrameworkService.meetingFramework
            case "builtin/research": fw = FrameworkService.researchFramework
            case "builtin/brainstorm": fw = FrameworkService.brainstormFramework
            case "builtin/journal": fw = FrameworkService.journalFramework
            case "builtin/blank": fw = FrameworkService.blankFramework
            default: return ToolResult(content: "Unknown framework ID: \(fwId). Use: builtin/meeting, builtin/research, builtin/brainstorm, builtin/journal, builtin/blank", citations: [], isError: true, displaySummary: "Unknown framework")
            }
            FrameworkService.shared.apply(to: project, framework: fw)
            try? context.modelContext.save()
            return ToolResult(content: "Project '\(project.name)' now uses the \(fw.name) framework.", citations: [], isError: false, displaySummary: "Framework: \(fw.name)")
        }

        return ToolResult(content: "Specify either framework_id (built-in) or framework_json (custom).", citations: [], isError: true, displaySummary: "Missing args")
    }
}

// MARK: - Content Processing Tools (Pipeline)

struct ExtractContentTool: AgentTool {
    let name = "extract_content"
    let description = """
    Extract text content from a knowledge item. For audio items, returns the transcript. \
    For images, returns OCR text. For notes/journal entries, returns the body text. \
    Use this before analyze_content to get the raw text to analyze.
    """

    let parameters = AIToolParameters(
        properties: [
            "item_id": AIToolProperty(type: "string", description: "UUID of the knowledge item to extract content from")
        ],
        required: ["item_id"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let itemIdStr = arguments["item_id"] as? String,
              let itemId = UUID(uuidString: itemIdStr) else {
            return ToolFormatting.error(tool: name, reason: "Missing or invalid item_id.", fix: "Provide a valid UUID string.")
        }

        let itemService = KnowledgeItemService(context: context.modelContext)
        guard let item = try? itemService.fetchItem(id: itemId) else {
            return ToolFormatting.error(tool: name, reason: "Item not found: \(itemIdStr)", fix: "Check the item_id and try again.")
        }

        let extraction = ContentExtractionService(modelContext: context.modelContext)
        let text: String?

        if item.audioFileRelativePath != nil {
            text = await extraction.extractTextFromAudio(item)
        } else {
            text = await extraction.extractTextFromDocument(item)
        }

        let effectiveText = text ?? extraction.bestAvailableText(for: item)
        guard let content = effectiveText, !content.isEmpty else {
            return ToolResult(
                content: "No extractable content found for item \(itemIdStr) (type: \(item.type.rawValue)). The item may need transcription first.",
                citations: [], isError: false,
                displaySummary: "extract: no content for \(item.title)"
            )
        }

        let truncated = String(content.prefix(ToolFormatting.maxContentChars))
        return ToolResult(
            content: truncated + (content.count > ToolFormatting.maxContentChars ? "\n\n[Content truncated at \(ToolFormatting.maxContentChars) chars. \(content.count - ToolFormatting.maxContentChars) more available.]" : ""),
            citations: [ChatCitation(itemId: item.id, title: item.title, snippet: String(content.prefix(200)), itemType: item.type)],
            isError: false,
            displaySummary: "extract: \(content.count) chars from \"\(item.title)\""
        )
    }
}

struct AnalyzeContentTool: AgentTool {
    let name = "analyze_content"
    let description = """
    Run structured AI analysis on text content. Extracts summary, decisions, action items, \
    risks, open questions, dates, and entities. For long content, uses map-reduce internally. \
    Returns the analysis as structured JSON.
    """

    let parameters = AIToolParameters(
        properties: [
            "item_id": AIToolProperty(type: "string", description: "UUID of the knowledge item to analyze"),
            "text": AIToolProperty(type: "string", description: "Text content to analyze. If omitted, extracts from the item first."),
            "model": AIToolProperty(type: "string", description: "Model: 'nano' for simple, 'gpt-5.5' for complex. Default: auto-select.")
        ],
        required: ["item_id"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let itemIdStr = arguments["item_id"] as? String,
              let itemId = UUID(uuidString: itemIdStr) else {
            return ToolFormatting.error(tool: name, reason: "Missing or invalid item_id.", fix: "Provide a valid UUID string.")
        }

        let itemService = KnowledgeItemService(context: context.modelContext)
        guard let item = try? itemService.fetchItem(id: itemId) else {
            return ToolFormatting.error(tool: name, reason: "Item not found: \(itemIdStr)", fix: "Check the item_id.")
        }

        let text: String
        if let provided = arguments["text"] as? String, !provided.isEmpty {
            text = provided
        } else {
            let extraction = ContentExtractionService(modelContext: context.modelContext)
            let extracted = await extraction.extractTextFromDocument(item)
                ?? extraction.bestAvailableText(for: item)
            guard let ext = extracted, !ext.isEmpty else {
                return ToolFormatting.error(tool: name, reason: "No text content for item.", fix: "Use extract_content first.")
            }
            text = ext
        }

        guard let provider = try? ProviderRouter.resolveActive(context: context.modelContext) else {
            return ToolFormatting.error(tool: name, reason: "No AI provider configured.", fix: "Configure a provider in Settings.")
        }

        let model: String
        if let requested = arguments["model"] as? String, !requested.isEmpty {
            model = requested
        } else {
            model = ModelTierResolver.resolveForAnalysis(item: item)
        }

        let extraction = ContentExtractionService(modelContext: context.modelContext)
        let sourceCtx = SourceContext.from(item)
        let segments = extraction.chunkText(text, itemID: item.id)
        let transcript = Transcript(meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: "agent-tool")

        do {
            let result = try await AnalysisService().analyze(
                transcript: transcript, using: provider, model: model,
                meetingId: item.id, sourceContext: sourceCtx
            )

            // Persist analysis to disk so exports and UI can read it
            let store = FileArtifactStore()
            try? store.createMeetingDirectory(for: item.id)
            try? store.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)

            // Write agent trace — proves the agent orchestrated this
            let trace: [String: Any] = [
                "agent_version": "2.0",
                "pipeline": "autonomous_agent",
                "model": model,
                "tool": "analyze_content",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            if let traceData = try? JSONSerialization.data(withJSONObject: trace),
               let traceJSON = String(data: traceData, encoding: .utf8) {
                try? traceJSON.write(to: store.itemDirectoryURL(for: item.id).appendingPathComponent("agent_trace.json"), atomically: true, encoding: .utf8)
            }

            // Update item status
            item.status = .analyzed
            item.analysisProviderId = model
            try? context.modelContext.save()

            let parts: [String] = [
                "**Analysis complete** (model: \(model))",
                "",
                "Short Summary: \(result.shortSummary)",
                result.detailedSummary.isEmpty ? "" : "Detailed: \(result.detailedSummary.prefix(500))",
                "Decisions: \(result.decisions.count)",
                "Action Items: \(result.actionItems.count)",
                "Risks: \(result.risks.count)",
                "Open Questions: \(result.openQuestions.count)",
                "Entities: \(result.entities.count)"
            ]
            return ToolResult(
                content: parts.filter { !$0.isEmpty }.joined(separator: "\n"),
                citations: [ChatCitation(itemId: item.id, title: item.title, snippet: result.shortSummary, itemType: item.type)],
                isError: false,
                displaySummary: "analyze: \"\(result.shortSummary.prefix(80))\""
            )
        } catch {
            return ToolResult(content: "Analysis failed: \(error.localizedDescription)", citations: [], isError: true, displaySummary: "analyze: failed")
        }
    }
}

struct DescribeImageTool: AgentTool {
    let name = "describe_image"
    let description = """
    Analyze an image file visually using AI vision. Returns OCR text (if any) and a visual \
    description of what's in the image. Use before analyze_content for image items.
    """

    let parameters = AIToolParameters(
        properties: [
            "item_id": AIToolProperty(type: "string", description: "UUID of the image item to describe"),
            "model": AIToolProperty(type: "string", description: "Model for vision. Default: gpt-5.5.")
        ],
        required: ["item_id"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let itemIdStr = arguments["item_id"] as? String,
              let itemId = UUID(uuidString: itemIdStr) else {
            return ToolFormatting.error(tool: name, reason: "Missing or invalid item_id.", fix: "Provide a valid UUID string.")
        }

        let itemService = KnowledgeItemService(context: context.modelContext)
        guard let item = try? itemService.fetchItem(id: itemId),
              let relativePath = item.imageFileRelativePath else {
            return ToolFormatting.error(tool: name, reason: "Item not found or not an image.", fix: "Provide the UUID of an image item.")
        }

        let imageURL = context.fileStore.itemDirectoryURL(for: itemId).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            return ToolFormatting.error(tool: name, reason: "Image file not found on disk.", fix: "The image may have been deleted.")
        }

        guard let provider = try? ProviderRouter.resolveActive(context: context.modelContext) else {
            return ToolFormatting.error(tool: name, reason: "No AI provider configured.", fix: "Configure a provider in Settings.")
        }

        let model = (arguments["model"] as? String) ?? AIConfigService.shared.featureConfig(for: "analysis")?.model ?? "gpt-5.5"

        do {
            let description = try await ImageAnalysisService().analyzeImage(imageURL, llmProvider: provider, model: model)
            guard !description.isEmpty else {
                return ToolResult(content: "Image analysis returned empty result.", citations: [], isError: false, displaySummary: "describe: empty")
            }
            let truncated = String(description.prefix(ToolFormatting.maxContentChars))
            return ToolResult(
                content: truncated,
                citations: [ChatCitation(itemId: item.id, title: item.title, snippet: String(description.prefix(200)), itemType: item.type)],
                isError: false,
                displaySummary: "describe: \(description.count) chars for \"\(item.title)\""
            )
        } catch {
            return ToolResult(content: "Image analysis failed: \(error.localizedDescription)", citations: [], isError: true, displaySummary: "describe: failed")
        }
    }
}

// MARK: - Prompt Management Tools (Phase 2)

struct ListPromptsTool: AgentTool {
    let name = "list_prompts"
    let description = "List all available prompt templates. Use 'category' to filter by type: analysis, chat, pipeline, system, custom."

    let parameters = AIToolParameters(
        properties: [
            "category": AIToolProperty(type: "string", description: "Filter by category: analysis, chat, pipeline, system, custom")
        ],
        required: []
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let category = arguments["category"] as? String
        let all = PromptStore.shared.prompts(in: category)
        let lines = all.map { p in
            "- `\(p.name)` [\(p.category)]\(p.isUserEdited ? " (edited)" : ""): \(p.description ?? "")"
        }
        return ToolResult(
            content: lines.joined(separator: "\n"),
            citations: [], isError: false,
            displaySummary: "prompts: \(all.count) templates"
        )
    }
}

struct ReadPromptTool: AgentTool {
    let name = "read_prompt"
    let description = "Read the full content of a prompt template by name. Use list_prompts first to discover available templates."

    let parameters = AIToolParameters(
        properties: [
            "name": AIToolProperty(type: "string", description: "Prompt name, e.g. 'analysis_system', 'pipeline_standard'")
        ],
        required: ["name"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let name = arguments["name"] as? String else {
            return ToolFormatting.error(tool: self.name, reason: "Missing 'name' parameter.", fix: "Provide a prompt name from list_prompts.")
        }
        guard let prompt = PromptStore.shared.prompt(named: name) else {
            return ToolFormatting.error(tool: self.name, reason: "Prompt '\(name)' not found.", fix: "Use list_prompts to see available templates.")
        }
        let status = prompt.isUserEdited ? " (user edited, \(prompt.updatedAt.formatted(date: .abbreviated, time: .shortened)))" : " (base)"
        let header = "**\(prompt.name)**\(status)\nCategory: \(prompt.category)\nVariables: \(prompt.variables.joined(separator: ", "))\n\n"
        return ToolResult(
            content: header + prompt.content,
            citations: [], isError: false,
            displaySummary: "read: \(prompt.name) (\(prompt.content.count) chars)"
        )
    }
}

struct EditPromptTool: AgentTool {
    let name = "edit_prompt"
    let description = "Update the content of a prompt template. Changes are persisted and take effect immediately. Use read_prompt first to see current content. Always confirm with the user before editing."

    let parameters = AIToolParameters(
        properties: [
            "name": AIToolProperty(type: "string", description: "Prompt name to edit"),
            "content": AIToolProperty(type: "string", description: "New prompt content (full replacement, not a diff)")
        ],
        required: ["name", "content"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let name = arguments["name"] as? String else {
            return ToolFormatting.error(tool: self.name, reason: "Missing 'name'.", fix: "Provide the prompt name to edit.")
        }
        guard let content = arguments["content"] as? String, !content.isEmpty else {
            return ToolFormatting.error(tool: self.name, reason: "Missing 'content'.", fix: "Provide the new prompt content.")
        }
        guard PromptStore.shared.prompt(named: name) != nil else {
            return ToolFormatting.error(tool: self.name, reason: "Prompt '\(name)' not found.", fix: "Use list_prompts first.")
        }
        PromptStore.shared.updatePrompt(named: name, content: content)
        return ToolResult(
            content: "Prompt '\(name)' updated successfully (\(content.count) chars).",
            citations: [], isError: false,
            displaySummary: "edit_prompt: '\(name)' updated"
        )
    }
}

// MARK: - Agent Memory Tools (Phase 3)

struct WriteMemoryTool: AgentTool {
    let name = "write_memory"
    let description = """
    Record a learned pattern or strategy so future pipeline runs can benefit. \
    After successfully processing an item, write what worked. \
    Provide: pattern (what you observed), strategy (what worked), and optional \
    item_type, language, min_duration, content_type for future matching.
    """

    let parameters = AIToolParameters(
        properties: [
            "pattern": AIToolProperty(type: "string", description: "What was observed, e.g. 'audio > 60min in Portuguese'"),
            "strategy": AIToolProperty(type: "string", description: "What worked, e.g. 'chunk 5k chars with nano, reduce with gpt-5.5'"),
            "item_type": AIToolProperty(type: "string", description: "audio, image, note"),
            "language": AIToolProperty(type: "string", description: "Language code: pt, en, etc."),
            "min_duration": AIToolProperty(type: "number", description: "Duration threshold in seconds"),
            "content_type": AIToolProperty(type: "string", description: "meeting, interview, document, photo")
        ],
        required: ["pattern", "strategy"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let pattern = arguments["pattern"] as? String,
              let strategy = arguments["strategy"] as? String else {
            return ToolFormatting.error(tool: name, reason: "Missing pattern or strategy.", fix: "Provide both the observed pattern and the strategy that worked.")
        }
        let mem = AgentMemoryStore.shared.write(
            pattern: pattern, strategy: strategy,
            itemType: arguments["item_type"] as? String,
            language: arguments["language"] as? String,
            minDuration: arguments["min_duration"] as? Double
        )
        return ToolResult(
            content: "Memory recorded: \(mem.id.uuidString.prefix(8)) — \"\(pattern.prefix(80))\"",
            citations: [], isError: false,
            displaySummary: "memory: \"\(pattern.prefix(60))\""
        )
    }
}

struct SearchMemoryTool: AgentTool {
    let name = "search_memory"
    let description = "Search agent memories for patterns that match the current content. Use before processing to find proven strategies."

    let parameters = AIToolParameters(
        properties: [
            "item_type": AIToolProperty(type: "string", description: "Filter by item type: audio, image, note"),
            "language": AIToolProperty(type: "string", description: "Filter by language: pt, en"),
            "content_type": AIToolProperty(type: "string", description: "Filter by content type: meeting, interview, document, photo")
        ],
        required: []
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let results = AgentMemoryStore.shared.search(
            itemType: arguments["item_type"] as? String,
            language: arguments["language"] as? String,
            contentType: arguments["content_type"] as? String
        )
        guard !results.isEmpty else {
            return ToolResult(content: "No relevant memories found for these criteria.", citations: [], isError: false, displaySummary: "memory search: 0 results")
        }
        let lines = results.map { m in
            "- [\(m.relevance > 0.8 ? "HIGH" : "MED")] \(m.pattern) → \(m.strategy) (success: \(m.successCount), fail: \(m.failCount))"
        }
        return ToolResult(
            content: "Found \(results.count) relevant memories:\n\n" + lines.joined(separator: "\n"),
            citations: [], isError: false,
            displaySummary: "memory search: \(results.count) results"
        )
    }
}

struct ListMemoriesTool: AgentTool {
    let name = "list_memories"
    let description = "List all agent memories (learned patterns and strategies)."

    let parameters = AIToolParameters(properties: [:], required: [])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let all = AgentMemoryStore.shared.listAll()
        guard !all.isEmpty else {
            return ToolResult(content: "No memories recorded yet.", citations: [], isError: false, displaySummary: "memories: 0")
        }
        let lines = all.map { m in
            "- \(m.isStale ? "[STALE] " : "")\(m.pattern) → \(m.strategy.prefix(80)) (\(m.successCount)S/\(m.failCount)F)"
        }
        return ToolResult(
            content: "\(all.count) agent memories:\n\n" + lines.joined(separator: "\n"),
            citations: [], isError: false,
            displaySummary: "memories: \(all.count)"
        )
    }
}

// MARK: - Plan Mode Tools (Phase 5)

struct PlanCreateTool: AgentTool {
    let name = "plan_create"
    let description = "Create a structured plan before executing a complex task. Use for multi-step operations like processing large items or research."

    let parameters = AIToolParameters(
        properties: [
            "steps": AIToolProperty(type: "array", description: "Array of step descriptions, e.g. [\"Extract content\", \"Analyze with nano\", \"Review and synthesize\"]"),
            "goal": AIToolProperty(type: "string", description: "What this plan aims to accomplish")
        ],
        required: ["steps", "goal"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let goal = arguments["goal"] as? String ?? "Unnamed plan"
        let steps = arguments["steps"] as? [String] ?? []
        var content = "**Plan: \(goal)**\n\n"
        for (i, step) in steps.enumerated() {
            content += "\(i + 1). [ ] \(step)\n"
        }
        return ToolResult(content: content, citations: [], isError: false, displaySummary: "plan: \(steps.count) steps")
    }
}

struct PlanUpdateTool: AgentTool {
    let name = "plan_update"
    let description = "Mark a plan step as completed. Use after finishing each step."

    let parameters = AIToolParameters(
        properties: [
            "step_index": AIToolProperty(type: "integer", description: "1-based index of the completed step"),
            "note": AIToolProperty(type: "string", description: "Optional note about the step outcome")
        ],
        required: ["step_index"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let idx = arguments["step_index"] as? Int ?? 0
        let note = arguments["note"] as? String ?? ""
        return ToolResult(
            content: "Step \(idx) completed.\(note.isEmpty ? "" : " Note: \(note)")",
            citations: [], isError: false,
            displaySummary: "plan: step \(idx) done"
        )
    }
}

// MARK: - Output Block Tools

/// Validates and returns a table block for native rendering.
struct RenderTableTool: AgentTool {
    let name = "render_table"
    let description = "Render tabular data as a native sortable table. Each row must have exactly the same number of cells as headers. Use for comparisons, inventories, decision matrices, etc."

    let parameters = AIToolParameters(properties: [
        "headers": AIToolProperty(type: "array", description: "Column headers"),
        "rows": AIToolProperty(type: "array", description: "Array of row arrays. Each row must match header count."),
        "title": AIToolProperty(type: "string", description: "Optional table title")
    ], required: ["headers", "rows"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let headers = args["headers"] as? [String], !headers.isEmpty else {
            return ToolResult(content: "render_table: headers required.", citations: [], isError: true, displaySummary: "render_table: bad headers")
        }
        guard let rows = args["rows"] as? [[String]] else {
            return ToolResult(content: "render_table: rows required as array of string arrays.", citations: [], isError: true, displaySummary: "render_table: bad rows")
        }
        // Validate row lengths
        for (i, row) in rows.enumerated() {
            if row.count != headers.count {
                return ToolResult(content: "render_table: row \(i+1) has \(row.count) columns, expected \(headers.count). Fix: each row must match: | \(headers.joined(separator: " | ")) |", citations: [], isError: true, displaySummary: "render_table: column mismatch")
            }
        }
        let title = args["title"] as? String
        // Persist as annotation so the table is recoverable
        if let itemId = context.activeProjectID {
            let annotationSvc = AnnotationService(context: context.modelContext)
            try? annotationSvc.upsert([
                CapturedAnnotation(source: "render_table", key: "headers", value: headers.joined(separator: "|"), confidence: nil),
                CapturedAnnotation(source: "render_table", key: "rowCount", value: String(rows.count), confidence: nil)
            ], itemID: itemId, source: "render_table")
        }
        return ToolResult(content: "render_table: \(headers.count) cols × \(rows.count) rows rendered.\(title.map { " Title: \"\($0)\"." } ?? "")", citations: [], isError: false, displaySummary: "table: \(headers.count)×\(rows.count)")
    }
}

/// Validates and renders action items with checkboxes. Items are persisted as TaskItems.
struct RenderActionsTool: AgentTool {
    let name = "render_actions"
    let description = "Render action items as native checkboxes. Each item can have owner, due date, and priority. Items are persisted as tasks. Use for todos, commitments, and follow-ups."

    let parameters = AIToolParameters(properties: [
        "items": AIToolProperty(type: "array", description: "Array of {task, owner?, due?, priority?} objects"),
        "title": AIToolProperty(type: "string", description: "Optional section title")
    ], required: ["items"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let items = args["items"] as? [[String: Any]] else {
            return ToolResult(content: "render_actions: items required as array of {task, owner?, due?, priority?}.", citations: [], isError: true, displaySummary: "render_actions: bad items")
        }
        var created = 0
        let taskSvc = TaskService(context: context.modelContext)
        for item in items {
            guard let taskTitle = item["task"] as? String else { continue }
            let owner = item["owner"] as? String
            let dueStr = item["due"] as? String
            let priorityStr = item["priority"] as? String
            let due: Date? = dueStr.flatMap { ISO8601DateFormatter().date(from: $0) }
            let priority = priorityStr.flatMap { TaskPriority(rawValue: $0) } ?? .medium
            let task = TaskItem(title: taskTitle, priority: priority, ownerName: owner, dueAt: due)
            context.modelContext.insert(task)
            created += 1
        }
        try? context.modelContext.save()
        return ToolResult(content: "render_actions: \(created) tasks created\(created > 0 ? " and rendered" : "").", citations: [], isError: false, displaySummary: "actions: \(created) tasks")
    }
}

/// Renders a card with title, body, entity chips, and optional badge.
struct RenderCardTool: AgentTool {
    let name = "render_card"
    let description = "Render a summary card with title, body text, entity tags, and an optional badge. Use for key findings, executive summaries, or item overviews."

    let parameters = AIToolParameters(properties: [
        "title": AIToolProperty(type: "string", description: "Card title"),
        "body": AIToolProperty(type: "string", description: "Card body text (markdown)"),
        "entities": AIToolProperty(type: "array", description: "Entity names to show as chips"),
        "badge": AIToolProperty(type: "string", description: "Optional badge text (e.g. 'HIGH', 'DONE')")
    ], required: ["title", "body"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let title = args["title"] as? String ?? ""
        let body = args["body"] as? String ?? ""
        let entities = args["entities"] as? [String] ?? []
        let badge = args["badge"] as? String
        return ToolResult(content: "render_card: \"\(title)\" rendered with \(entities.count) entities.\(badge.map { " Badge: \($0)." } ?? "")", citations: [], isError: false, displaySummary: "card: \(title)")
    }
}

/// Renders a code block with syntax highlighting and copy button.
struct RenderCodeTool: AgentTool {
    let name = "render_code"
    let description = "Render a code block with syntax highlighting and a copy button. Use for scripts, queries, config examples, or structured data."

    let parameters = AIToolParameters(properties: [
        "code": AIToolProperty(type: "string", description: "Code content"),
        "language": AIToolProperty(type: "string", description: "Programming language for syntax highlighting"),
        "caption": AIToolProperty(type: "string", description: "Optional caption below the code block")
    ], required: ["code"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let code = args["code"] as? String ?? ""
        let lang = args["language"] as? String
        let caption = args["caption"] as? String
        return ToolResult(content: "render_code: \(code.count) chars\(lang.map { " (\($0))" } ?? "").", citations: [], isError: false, displaySummary: "code: \(code.count) chars")
    }
}

/// Renders a chart using native Swift Charts. Supports bar, line, pie, and scatter.
struct RenderChartTool: AgentTool {
    let name = "render_chart"
    let description = "Render a native chart. Supported types: bar, line, pie, scatter. Labels array for X axis. Data as array of {label, value} or {label, values:[]} for multi-series."

    let parameters = AIToolParameters(properties: [
        "type": AIToolProperty(type: "string", description: "Chart type: bar, line, pie, scatter"),
        "labels": AIToolProperty(type: "array", description: "X-axis labels"),
        "data": AIToolProperty(type: "array", description: "Array of {label, value} or {label, values:[]} for multi-series")
    ], required: ["type", "labels", "data"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let type = args["type"] as? String ?? "bar"
        let labels = args["labels"] as? [String] ?? []
        let _ = args["data"] as? [[String: Any]] ?? []
        guard !labels.isEmpty else {
            return ToolResult(content: "render_chart: labels required.", citations: [], isError: true, displaySummary: "chart: bad labels")
        }
        return ToolResult(content: "render_chart: \(type) chart with \(labels.count) data points rendered.", citations: [], isError: false, displaySummary: "chart: \(type) (\(labels.count) pts)")
    }
}

// MARK: - JavaScript Execution Tool

/// Executes JavaScript code in a sandboxed JSContext with access to native APIs.
/// The code runs with a 5-second timeout. Use `native.getAllItems()` etc.
struct ExecuteJavaScriptTool: AgentTool {
    let name = "execute_javascript"
    let description = """
    Execute JavaScript code in a secure sandbox with access to native APIs via `native.*`. \
    Available APIs: native.getAllItems(), native.searchItems(query), native.getItem(id), \
    native.getItemAnalysis(id), native.getProject(id), native.getProjectTasks(projectId), \
    native.createTask(title, owner, due, projectId), native.jsLog(msg), native.jsNow(). \
    Use console.log() for debugging. 5-second timeout. No network, no fs, no require.
    """

    let parameters = AIToolParameters(properties: [
        "code": AIToolProperty(type: "string", description: "JavaScript code to execute"),
        "description": AIToolProperty(type: "string", description: "Brief description of what this script does")
    ], required: ["code"])

    func execute(_ args: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let code = args["code"] as? String, !code.isEmpty else {
            return ToolFormatting.error(tool: name, reason: "Missing 'code'.", fix: "Provide JavaScript code to execute.")
        }
        let desc = args["description"] as? String ?? ""

        let bridge = WawaJSBridge(modelContext: context.modelContext, fileStore: context.fileStore)
        let result = JSSandbox.execute(code, bridge: bridge)

        if let error = result.error {
            let msg = """
            JavaScript execution failed:

            **Description:** \(desc)
            **Error:** \(error)

            Fix the code and retry. Check for:
            - Syntax errors (missing brackets, semicolons)
            - API misuse (check `native.*` function signatures)
            - Infinite loops (5s timeout)
            """
            return ToolResult(content: msg, citations: [], isError: true, displaySummary: "JS: error — \(error.prefix(60))")
        }

        let logSection = result.logs.isEmpty ? "" : "\n\n**Console output:**\n\(result.logs.map { "  > \($0)" }.joined(separator: "\n"))"
        return ToolResult(
            content: "**JS result** (\(desc)):\n\(result.output)\(logSection)",
            citations: [], isError: false,
            displaySummary: "JS: \(desc.isEmpty ? code.prefix(40) : desc.prefix(60))"
        )
    }
}

// MARK: - Semantic Search Tool (Phase I)

struct SearchSemanticTool: AgentTool {
    let name = "search_semantic"
    let description = "Semantic search across knowledge items using embeddings. Finds conceptually similar content even when keywords don't match. Use for broad research questions, thematic exploration, and finding related items by meaning."

    let parameters = AIToolParameters(properties: [
        "query": AIToolProperty(type: "string", description: "Natural language question or concept to search for"),
        "limit": AIToolProperty(type: "integer", description: "Max results (default 10)")
    ], required: ["query"])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return ToolFormatting.error(tool: name, reason: "Missing query.", fix: "Provide a search query.")
        }
        let limit = min((arguments["limit"] as? Int) ?? 10, 20)
        let itemSvc = KnowledgeItemService(context: context.modelContext)
        let items = (try? itemSvc.allItems()) ?? []

        // Try semantic search first (embeddings), fall back to FTS
        let embeddingSvc = EmbeddingService()
        let embStore = FileArtifactStore()
        var scored: [(item: KnowledgeItem, score: Double, snippet: String)] = []

        // Generate embedding for query
        guard let provider = try? ProviderRouter.resolveActive(context: context.modelContext) else {
            return ToolFormatting.error(tool: name, reason: "No provider for embeddings.", fix: "Configure a provider in Settings.")
        }
        let queryEmbedding: [Float]
        let tmpID = UUID()
        do {
            queryEmbedding = try await embeddingSvc.generateAndStore(for: tmpID, text: query, using: provider)
        } catch {
            // Fallback to FTS
            let ftsResults = SearchService().searchNow(query: query, in: items).prefix(limit)
            let lines = ftsResults.map { r in "- \(items.first(where: {$0.id == r.itemID})?.title ?? "??"): \(r.snippet)" }
            return ToolResult(content: "FTS results (embeddings unavailable):\n" + lines.joined(separator: "\n"), citations: [], isError: false, displaySummary: "search: \(ftsResults.count) FTS")
        }

        // Score items by cosine similarity
        for item in items {
            guard let emb = embeddingSvc.load(for: item.id), !emb.isEmpty else { continue }
            let sim = Double(SemanticSearchService().cosineSimilarity(queryEmbedding, emb))
            if sim > 0.3 { // Minimum relevance threshold
                let snippet: String = item.bodyText.map { String($0.prefix(200)) } ?? item.title
                scored.append((item, sim, snippet))
            }
        }

        // Clean up temporary embedding
        try? FileManager.default.removeItem(at: embeddingSvc.embeddingURL(for: tmpID))

        scored.sort { $0.score > $1.score }
        let top = scored.prefix(limit)
        guard !top.isEmpty else {
            return ToolResult(content: "No semantically relevant items found for \"\(query)\". Try different wording or use search_knowledge for keyword search.", citations: [], isError: false, displaySummary: "semantic: 0 results")
        }

        var content = "Semantic search results for \"\(query)\":\n\n"
        var citations: [ChatCitation] = []
        for (i, r) in top.enumerated() {
            content += "\(i+1). **\(r.item.title)** (score: \(String(format: "%.0f", r.score * 100))%)\n   \(r.snippet)\n\n"
            citations.append(ChatCitation(itemId: r.item.id, title: r.item.title, snippet: r.snippet, itemType: r.item.type))
        }
        return ToolResult(content: content, citations: citations, isError: false, displaySummary: "semantic: \(top.count) results")
    }
}
