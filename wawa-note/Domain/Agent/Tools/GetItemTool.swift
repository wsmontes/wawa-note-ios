import Foundation

struct GetItemTool: AgentTool {
    let name = "get_item"
    let description = "Fetch a specific knowledge item by its full UUID. Returns title, type, body text, tags, creation date, transcript excerpts (for meetings), and analysis summaries."

    let parameters = AIToolParameters(
        properties: ["item_id": AIToolProperty(type: "string", description: "Full UUID of the item (from search_knowledge or list_items results)")],
        required: ["item_id"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let rawId = (arguments["item_id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""

        // Show what arguments were actually received
        let receivedArgs = arguments.keys.sorted().joined(separator: ", ")
        let receivedSummary = arguments.isEmpty ? "NO arguments received" : "Received keys: [\(receivedArgs)]"

        guard !rawId.isEmpty else {
            return ToolFormatting.error(
                tool: name,
                reason: "Missing required parameter 'item_id'. \(receivedSummary).",
                fix: "Use search_knowledge first to find items, then call get_item with the full UUID from the search results. Example: get_item(item_id: \"B5F73B5F-XXXX-XXXX-XXXX-XXXXXXXXXXXX\")\n\nIMPORTANT: If you don't have a UUID, search first. Never call get_item without a valid UUID."
            )
        }
        guard UUID(uuidString: rawId) != nil else {
            return ToolFormatting.error(
                tool: name,
                reason: "'\(rawId)' is not a valid UUID. \(receivedSummary).",
                fix: "The value you passed is not a valid UUID. Get the full UUID (36 characters with dashes) from search_knowledge or list_items results. Do not truncate or modify the UUID."
            )
        }
        let itemId = UUID(uuidString: rawId)!
        let svc = KnowledgeItemService(context: context.modelContext)
        guard let item = try svc.fetchItem(id: itemId) else {
            return ToolFormatting.error(tool: name, reason: "No item found with UUID \(rawId.prefix(20))...", fix: "Try search_knowledge or list_items to find valid UUIDs.")
        }

        var content = "## \(item.title.isEmpty ? "Untitled" : item.title)\n"
        content += "Type: \(item.type.label) | Created: \(item.createdAt.formatted(date: .complete, time: .shortened))\n"
        if let dur = item.durationSeconds { content += "Duration: \(Int(dur/60))m \(Int(dur)%60)s\n" }
        if !item.tags.isEmpty { content += "Tags: \(item.tags.joined(separator: ", "))\n" }
        content += "UUID: \(item.id.uuidString)\n"

        if let body = item.bodyText, !body.isEmpty {
            let preview = body.count > 1000 ? String(body.prefix(1000)) + "\n... [truncated, \(body.count) total chars]" : body
            content += "\n### Content\n\(preview)\n"
        }

        if item.type == .meeting {
            if let t = try? context.fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
                let excerpt = t.segments.prefix(15).map { "[\(Int($0.startTime))s] \($0.text)" }.joined(separator: "\n")
                content += "\n### Transcript (\(t.segments.count) segments)\n\(excerpt)"
                if t.segments.count > 15 { content += "\n... +\(t.segments.count - 15) more segments. Full transcript available in app." }
                content += "\n"
            }
            if let a = try? context.fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
                content += "\n### AI Analysis\n\(a.shortSummary)\n"
                if !a.decisions.isEmpty {
                    content += "\n**Decisions:**\n" + a.decisions.map { "- \($0.title)" }.joined(separator: "\n") + "\n"
                }
                if !a.actionItems.isEmpty {
                    content += "\n**Action Items:**\n" + a.actionItems.map { "- \($0.task) (owner: \($0.owner ?? "unassigned"))" }.joined(separator: "\n") + "\n"
                }
            }
        }

        return ToolFormatting.success(
            summary: "get_item: \(item.title)",
            content: content,
            citations: [ChatCitation(itemId: item.id, title: item.title, snippet: String(content.prefix(100)), itemType: item.typeRaw)],
            totalFound: 1, shown: 1
        )
    }
}
