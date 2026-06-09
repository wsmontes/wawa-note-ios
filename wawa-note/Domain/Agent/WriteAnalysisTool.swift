import Foundation

/// Dedicated tool for writing analysis JSON.
///
/// Replaces the fragile `echo '{"complex":"json"}' > /path` VFS command
/// with a clean parameter-based API the LLM can call directly.
///
/// Usage: write_analysis(itemId, analysisJson)
/// - itemId: the knowledge item UUID
/// - analysisJson: the complete analysis JSON string
struct WriteAnalysisTool: AgentTool {
    let name = "write_analysis"
    let description = """
        Write the analysis result for a knowledge item.
        Use after extract to save your structured analysis.
        The analysisJson must be valid JSON with shortSummary, decisions, actionItems, risks, openQuestions.
        Example: write_analysis(itemId="...", analysisJson="{\\"shortSummary\\":\\"...\\",...}")
        """
    let parameters = AIToolParameters(
        properties: [
            "itemId": AIToolProperty(
                type: "string",
                description: "The knowledge item UUID to write analysis for"
            ),
            "analysisJson": AIToolProperty(
                type: "string",
                description: "Complete analysis JSON string"
            )
        ],
        required: ["itemId", "analysisJson"]
    )

    @MainActor
    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let itemIdStr = arguments["itemId"] as? String,
              let itemId = UUID(uuidString: itemIdStr) else {
            return ToolResult(content: "Error: itemId must be a valid UUID",
                              isError: true, displaySummary: "Invalid itemId")
        }

        guard let jsonStr = arguments["analysisJson"] as? String else {
            return ToolResult(content: "Error: analysisJson is required",
                              isError: true, displaySummary: "Missing JSON")
        }

        // Parse JSON
        guard let data = jsonStr.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolResult(content: "Error: analysisJson is not valid JSON",
                              isError: true, displaySummary: "Invalid JSON")
        }

        // Normalize keys: accept both snake_case and camelCase
        json = normalizeKeys(json)

        // Check required field
        let hasSummary = (json["shortSummary"] as? String)?.isEmpty == false
        if !hasSummary {
            return ToolResult(content: "Error: analysis must include 'shortSummary' field with a one-line summary",
                              isError: true, displaySummary: "Missing shortSummary")
        }

        // Write normalized JSON
        let fileStore = FileArtifactStore()
        do {
            let normalizedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try fileStore.createMeetingDirectory(for: itemId)
            let url = fileStore.itemDirectoryURL(for: itemId).appendingPathComponent("analysis.json")
            try normalizedData.write(to: url, options: .atomic)
            let fieldCount = json.count
            return ToolResult(
                content: "Analysis written (\(fieldCount) fields)",
                displaySummary: "Analysis saved (\(fieldCount) fields)"
            )
        } catch {
            return ToolResult(content: "Error writing analysis: \(error.localizedDescription)",
                              isError: true, displaySummary: "Write failed")
        }

    }

    /// Normalize JSON keys from snake_case to camelCase.
    /// Both formats are accepted — output is always camelCase for MeetingAnalysis.
    private func normalizeKeys(_ json: [String: Any]) -> [String: Any] {
        let keyMap: [String: String] = [
            "short_summary": "shortSummary",
            "detailed_summary": "detailedSummary",
            "action_items": "actionItems",
            "open_questions": "openQuestions",
            "important_dates": "importantDates",
            "due_date": "dueDate",
            "source_segment_ids": "sourceSegmentIds",
        ]
        var result: [String: Any] = [:]
        for (key, value) in json {
            let mapped = keyMap[key] ?? key
            if let nested = value as? [String: Any] {
                result[mapped] = normalizeKeys(nested)
            } else if let arr = value as? [[String: Any]] {
                result[mapped] = arr.map { normalizeKeys($0) }
            } else {
                result[mapped] = value
            }
        }
        return result
    }
}
