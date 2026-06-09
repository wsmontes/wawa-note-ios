import Foundation

/// Dedicated tool for writing analysis JSON.
///
/// The LLM writes JSON using the template's section names as keys.
/// The JSON is stored as-is — the UI renders dynamically from the template
/// sections, so any template works without key normalization.
///
/// Usage: write_analysis(itemId, analysisJson)
struct WriteAnalysisTool: AgentTool {
    let name = "write_analysis"
    let description = """
        Write the analysis result for a knowledge item.
        Use after extract to save your structured analysis.
        The JSON keys should match the section titles from the template.
        Example: write_analysis(itemId="...", analysisJson='{"Summary":"...","Key Decisions":[...]}')
        """
    let parameters = AIToolParameters(
        properties: [
            "itemId": AIToolProperty(
                type: "string",
                description: "The knowledge item UUID to write analysis for"
            ),
            "analysisJson": AIToolProperty(
                type: "string",
                description: "Complete analysis JSON. Keys = template section titles."
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

        // Validate JSON
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else {
            return ToolResult(content: "Error: analysisJson is not valid JSON or is empty",
                              isError: true, displaySummary: "Invalid JSON")
        }

        // Write as-is — no key normalization. The template defines the section names,
        // the LLM uses them as keys, the UI renders dynamically from the template.
        let fileStore = FileArtifactStore()
        do {
            try fileStore.createMeetingDirectory(for: itemId)

            // Write the original JSON for DynamicAnalysis rendering
            let prettyData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let url = fileStore.itemDirectoryURL(for: itemId).appendingPathComponent("analysis.json")
            try prettyData.write(to: url, options: .atomic)

            return ToolResult(
                content: "Analysis written (\(json.count) sections)",
                displaySummary: "Analysis saved"
            )
        } catch {
            return ToolResult(content: "Error writing analysis: \(error.localizedDescription)",
                              isError: true, displaySummary: "Write failed")
        }
    }
}
