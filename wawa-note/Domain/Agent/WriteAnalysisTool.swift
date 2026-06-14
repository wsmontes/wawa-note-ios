import Foundation

/// Dedicated tool for writing analysis JSON.
///
/// The LLM writes JSON using the template's section names as keys.
/// The JSON is stored as-is — the UI renders dynamically from the template
/// sections, so any template works without key normalization.
///
/// Safety guarantees:
/// - Validates itemId is a valid UUID
/// - Creates a backup of the previous analysis before overwriting
/// - Enforces a maximum JSON size (1 MB) to prevent runaway writes
/// - Uses atomicWriteWithBackup for corruption-resistant persistence
/// - Adds provenance metadata (writtenBy, timestamp) to the stored JSON
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

    /// Maximum allowed size for analysis JSON in bytes (1 MB).
    /// Larger payloads are rejected to prevent runaway LLM output from
    /// filling the disk with repetitive or hallucinated content.
    private static let maxAnalysisSize = 1_048_576 // 1 MB

    @MainActor
    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let itemIdStr = arguments["itemId"] as? String,
              let itemId = UUID(uuidString: itemIdStr) else {
            let raw = String(describing: arguments["itemId"])
            AppLog.provider.error("write_analysis: invalid itemId '\(raw)'")
            return ToolResult(content: "Error: itemId must be a valid UUID. Received: \(raw)",
                              isError: true, displaySummary: "Invalid itemId")
        }

        guard let jsonStr = arguments["analysisJson"] as? String else {
            AppLog.provider.error("write_analysis: missing analysisJson")
            return ToolResult(content: "Error: analysisJson is required",
                              isError: true, displaySummary: "Missing JSON")
        }

        // Reject oversized payloads before any file I/O
        guard jsonStr.utf8.count <= Self.maxAnalysisSize else {
            let sizeMB = Double(jsonStr.utf8.count) / 1_048_576.0
            AppLog.provider.error("write_analysis: analysisJson too large — \(String(format: "%.1f", sizeMB)) MB (max 1 MB)")
            return ToolResult(content: "Error: analysisJson exceeds 1 MB maximum. Please reduce the content size.",
                              isError: true, displaySummary: "Content too large")
        }

        // Validate JSON structure
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else {
            let preview = String(jsonStr.prefix(200))
            AppLog.provider.error("write_analysis: invalid JSON: \(preview)")
            return ToolResult(content: "Error: analysisJson is not valid JSON. Check for unescaped quotes, trailing commas, or missing braces. First 200 chars: \(preview)",
                              isError: true, displaySummary: "Invalid JSON")
        }

        // Add provenance metadata so consumers know who wrote this and when
        var enrichedJSON = json
        enrichedJSON["_metadata"] = [
            "writtenBy": "WriteAnalysisTool",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sectionCount": json.count
        ]

        let fileStore = FileArtifactStore()
        do {
            try fileStore.createMeetingDirectory(for: itemId)

            let prettyData = try JSONSerialization.data(withJSONObject: enrichedJSON, options: [.prettyPrinted, .sortedKeys])
            let url = fileStore.itemDirectoryURL(for: itemId).appendingPathComponent(AppFileConstants.analysisFileName)

            // Use atomicWriteWithBackup for corruption-resistant persistence.
            // If this write fails, the previous analysis.json (and .BAK) remain intact.
            try fileStore.atomicWriteWithBackup(data: prettyData, url: url)

            // Verify the write by reading back and comparing sizes.
            // Prevents silent failures (e.g. disk full, truncated write, APFS corruption).
            guard let verifyData = try? Data(contentsOf: url),
                  abs(verifyData.count - prettyData.count) <= 1 else {
                AppLog.provider.error("write_analysis: read-back verification failed — size mismatch")
                return ToolResult(content: "Error: analysis write verification failed — the file may be corrupted. Please retry.",
                                  isError: true, displaySummary: "Write verification failed")
            }

            AppLog.provider.info("write_analysis: saved \(json.count) sections (\(prettyData.count) bytes) to \(url.path)")

            // ── Framework schema validation ──────────────────────────
            // If a framework is active, validate the output and return
            // specific fix instructions so the agent can correct its output
            // in the next iteration without restarting the pipeline.
            var validationNote = ""
            if let fw = context.activeFramework {
                let errors = FrameworkService.validateAnalysis(json: json, against: fw)
                if let errors {
                    let errorList = errors.components(separatedBy: "\n").prefix(5).joined(separator: "\n")
                    validationNote = """

                    ⚠️ SCHEMA VALIDATION ISSUES (fix and call write_analysis again):
                    Framework: \(fw.name)
                    \(errorList)

                    Required fields: \((fw.itemAnalysis.outputSchema.required ?? Array(fw.itemAnalysis.outputSchema.properties.keys)).joined(separator: ", "))

                    Fix your analysis JSON to include all required fields with correct types, then call write_analysis again.
                    """
                    AppLog.provider.warning("write_analysis: schema validation failed — \(fw.name): \(errors)")
                } else {
                    AppLog.provider.info("write_analysis: schema validation passed — \(fw.name)")
                }
            }
            // ── End schema validation ──────────────────────────────────

            let successMsg = "Analysis written (\(json.count) sections, \(prettyData.count) bytes) to analysis.json.\(validationNote)"
            return ToolResult(
                content: successMsg,
                displaySummary: validationNote.isEmpty ? "Analysis saved" : "Analysis saved — needs fixes"
            )
        } catch {
            AppLog.provider.error("write_analysis: write failed: \(error.localizedDescription)")
            return ToolResult(content: "Error writing analysis: \(error.localizedDescription)",
                              isError: true, displaySummary: "Write failed")
        }
    }
}
