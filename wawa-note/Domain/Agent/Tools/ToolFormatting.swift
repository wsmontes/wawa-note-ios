import Foundation

enum ToolFormatting {
    static let maxContentChars = 2500
    static let maxResultsDefault = 15

    // MARK: - Error formatting

    static func error(
        tool: String,
        reason: String,
        fix: String,
        receivedArgs: String? = nil
    ) -> ToolResult {
        var content = """
        [ERROR] \(tool)
        What went wrong: \(reason)
        """
        if let args = receivedArgs {
            content += "Arguments you sent: \(args)\n"
        }
        content += """
        How to fix: \(fix)
        """
        return ToolResult(content: content, citations: [], isError: true, displaySummary: "\(tool): \(reason)")
    }

    // MARK: - Success formatting with truncation

    static func success(
        summary: String,
        content: String,
        citations: [ChatCitation],
        totalFound: Int,
        shown: Int
    ) -> ToolResult {
        var finalContent = content
        if totalFound > shown {
            finalContent += """

            ---
            Showing \(shown) of \(totalFound) results. To see more, use a more specific query or increase the limit parameter.
            """
        }
        if finalContent.count > maxContentChars {
            let truncated = String(finalContent.prefix(maxContentChars))
            finalContent = truncated + """

            ---
            [TRUNCATED] Response exceeded \(maxContentChars) chars. Results were cut short.
            To get more details, use get_item with specific UUIDs to fetch individual items.
            To narrow results, use more specific queries or filters.
            """
        }
        return ToolResult(content: finalContent, citations: citations, isError: false, displaySummary: summary)
    }

    // MARK: - Item formatting

    static func formatItemLine(_ item: KnowledgeItem, index: Int) -> String {
        var line = "\(index). [\(item.type.label)] **\(item.title.isEmpty ? "Untitled" : item.title)**\n"
        line += "   UUID: \(item.id.uuidString)\n"
        line += "   Created: \(item.createdAt.formatted(date: .abbreviated, time: .shortened))\n"
        if let body = item.bodyText, !body.isEmpty {
            let preview = String(body.prefix(100)).replacingOccurrences(of: "\n", with: " ")
            line += "   Preview: \(preview)\(body.count > 100 ? "..." : "")\n"
        }
        if let duration = item.durationSeconds { line += "   Duration: \(Int(duration/60))m\n" }
        if !item.tags.isEmpty { line += "   Tags: \(item.tags.joined(separator: ", "))\n" }
        return line
    }

    static func formatTaskLine(_ task: TaskItem, index: Int) -> String {
        var line = "\(index). [\(task.statusRaw)] **\(task.title)**\n"
        line += "   Priority: \(task.priorityRaw) | Owner: \(task.ownerName ?? "unassigned")\n"
        if let due = task.dueAt { line += "   Due: \(due.formatted(date: .abbreviated, time: .omitted))\n" }
        if let src = task.sourceItemID { line += "   Source item UUID: \(src.uuidString)\n" }
        return line
    }

    static func formatEdgeLine(_ edge: GraphEdge, label: String) -> String {
        "→ \(edge.edgeType.rawValue) → \(label) (weight: \(String(format: "%.2f", edge.weight)))\n"
    }
}
