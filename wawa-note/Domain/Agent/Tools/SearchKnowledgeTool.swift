import Foundation

struct SearchKnowledgeTool: AgentTool {
    let name = "search_knowledge"
    let description = "Full-text search across all knowledge items (audio, notes, journals, bookmarks, images). Searches titles, body text, transcripts, and analysis summaries. Returns item UUIDs for use with get_item."

    let parameters = AIToolParameters(
        properties: [
            "query": AIToolProperty(type: "string", description: "The search query. Use specific keywords for best results."),
            "limit": AIToolProperty(type: "integer", description: "Max results (default 10, max 20)")
        ],
        required: ["query"]
    )

    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolFormatting.error(tool: name, reason: "Missing required parameter 'query'.", fix: "Provide a non-empty search query string.")
        }

        let limit = min((arguments["limit"] as? Int) ?? 10, 20)
        let svc = KnowledgeItemService(context: context.modelContext)
        let items = (try? svc.allItems()) ?? []
        let searchService = SearchService(fileStore: context.fileStore)
        let results = Array(searchService.searchNow(query: query, in: items).prefix(limit))

        if results.isEmpty {
            let suggestions = items.prefix(5).map { "  - \($0.title) (\($0.type.label))" }.joined(separator: "\n")
            let tip = """
            No results found for "\(query)" in \(items.count) items.

            Tips:
            - Try shorter or different keywords
            - Check spelling
            - Use list_items to browse by type or date instead
            - Recent items:
            \(suggestions)
            """
            return ToolResult(content: tip, citations: [], isError: false, displaySummary: "search: 0 results for \"\(query)\"")
        }

        var content = "Found \(results.count) of \(items.count) items matching \"\(query)\":\n\n"
        var citations: [ChatCitation] = []

        for (idx, r) in results.enumerated() {
            guard let item = items.first(where: { $0.id == r.itemID }) else { continue }
            content += ToolFormatting.formatItemLine(item, index: idx + 1)
            content += "   Matched in: \(r.matchedField.rawValue)\n"
            content += "   Snippet: \"\(r.snippet)\"\n\n"
            citations.append(ChatCitation(itemId: r.itemID, title: item.title, snippet: r.snippet, itemType: item.type,
                projectID: item.projectID, projectColorHex: item.projectID.flatMap { context.projectColorHex(for: $0) }))
        }

        content += "To read a full item, use get_item with its UUID."

        return ToolFormatting.success(
            summary: "search \"\(query)\": \(results.count) results",
            content: content,
            citations: citations,
            totalFound: results.count,
            shown: results.count
        )
    }
}
