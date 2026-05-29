import Foundation

struct ListItemsTool: AgentTool {
    let name = "list_items"
    let description = "List knowledge items filtered by type, date range, or search. Returns item UUIDs for use with get_item. Good for browsing when you don't have a specific query."

    let parameters = AIToolParameters(properties: [
        "item_type": AIToolProperty(type: "string", description: "Filter: meeting, note, journalEntry, webBookmark, image"),
        "limit": AIToolProperty(type: "integer", description: "Max results (default 15, max 30)"),
        "date_from": AIToolProperty(type: "string", description: "ISO 8601 date (YYYY-MM-DD)"),
        "date_to": AIToolProperty(type: "string", description: "ISO 8601 date (YYYY-MM-DD)")
    ], required: [])

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        let svc = KnowledgeItemService(context: context.modelContext)
        var items = (try? svc.allItems()) ?? []
        let limit = min((arguments["limit"] as? Int) ?? 15, 30)

        if let typeStr = arguments["item_type"] as? String {
            guard let kt = KnowledgeItemType(rawValue: typeStr) else {
                let valid = KnowledgeItemType.allCases.map(\.rawValue).joined(separator: ", ")
                return ToolFormatting.error(tool: name, reason: "Invalid item_type '\(typeStr)'.", fix: "Use one of: \(valid)")
            }
            items = items.filter { $0.type == kt }
        }
        if let from = arguments["date_from"] as? String {
            guard let d = ISO8601DateFormatter().date(from: from + "T00:00:00Z") else {
                return ToolFormatting.error(tool: name, reason: "Invalid date_from '\(from)'.", fix: "Use ISO 8601 format: YYYY-MM-DD")
            }
            items = items.filter { $0.createdAt >= d }
        }
        if let to = arguments["date_to"] as? String {
            guard let d = ISO8601DateFormatter().date(from: to + "T00:00:00Z") else {
                return ToolFormatting.error(tool: name, reason: "Invalid date_to '\(to)'.", fix: "Use ISO 8601 format: YYYY-MM-DD")
            }
            items = items.filter { $0.createdAt <= d }
        }

        let result = Array(items.prefix(limit))

        if result.isEmpty {
            return ToolResult(content: "No items found matching the filters. Try different criteria or use search_knowledge instead.", citations: [], isError: false, displaySummary: "list_items: 0 results")
        }

        var content = "Found \(result.count) of \(items.count) items:\n\n"
        for (idx, item) in result.enumerated() {
            content += ToolFormatting.formatItemLine(item, index: idx + 1) + "\n"
        }
        content += "To read a full item, use get_item with its UUID."

        return ToolFormatting.success(summary: "list_items: \(result.count) results", content: content, citations: [], totalFound: items.count, shown: result.count)
    }
}
