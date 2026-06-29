import Foundation
import SwiftData

// MARK: - Analysis Schema

/// Defines the output structure for item-level analysis.
/// Schemas are independent of skills — the agent selects both based on content.
struct AnalysisSchema: Codable, Sendable {
    let name: String
    let displayName: String
    let description: String
    let category: String
    let outputSchema: OutputSchema

    struct OutputSchema: Codable, Sendable {
        let properties: [String: PropertyDef]
        let required: [String]?

        struct PropertyDef: Codable, Sendable {
            let type: String
            let description: String?
            let items: ItemsDef?
            let properties: [String: PropertyDef]?
            let `enum`: [String]?

            struct ItemsDef: Codable, Sendable {
                let type: String?
                let properties: [String: PropertyDef]?
            }
        }
    }
}

// MARK: - Schema Store (hardcoded — mirrors AnalysisSkillStore pattern)

@MainActor
final class AnalysisSchemaStore {
    static let shared = AnalysisSchemaStore()

    let schemas: [String: AnalysisSchema]

    private init() {
        schemas = Self.builtInSchemas()
    }

    func schema(named name: String) -> AnalysisSchema? { schemas[name] }

    func catalog() -> String {
        schemas.values.sorted { $0.displayName < $1.displayName }.map {
            "\($0.name) — \($0.displayName): \($0.description)"
        }.joined(separator: "\n")
    }

    private static func builtInSchemas() -> [String: AnalysisSchema] {
        let raw: [(String, String, String, String, [String: Any])] = [
            (
                "decisions_actions", "Decisions & Actions", "Meeting-like: decisions, tasks, risks, open questions", "meeting",
                [
                    "short_summary": ["type": "string"],
                    "decisions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"], "details": ["type": "string"], "rationale": ["type": "string"],
                            ],
                        ],
                    ],
                    "action_items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "task": ["type": "string"], "owner": ["type": "string"], "due_date": ["type": "string"],
                            ],
                        ],
                    ],
                    "risks": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "risk": ["type": "string"], "impact": ["type": "string"], "mitigation": ["type": "string"],
                            ],
                        ],
                    ],
                    "open_questions": ["type": "array", "items": ["type": "string"]],
                    "key_points": ["type": "array", "items": ["type": "string"]],
                ]
            ),
            (
                "thematic_analysis", "Thematic Analysis", "Themes, patterns, contradictions, and insights across content", "analysis",
                [
                    "short_summary": ["type": "string"],
                    "themes": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"], "evidence": ["type": "string"],
                                "strength": ["type": "string", "enum": ["strong", "moderate", "weak"]],
                            ],
                        ],
                    ],
                    "insights": ["type": "array", "items": ["type": "string"]],
                    "contradictions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "statement_a": ["type": "string"], "statement_b": ["type": "string"], "resolution": ["type": "string"],
                            ],
                        ],
                    ],
                    "people_mentioned": ["type": "array", "items": ["type": "string"]],
                    "entities": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"], "type": ["type": "string"],
                            ],
                        ],
                    ],
                ]
            ),
            (
                "qa_transcript", "Q&A Transcript", "Q&A exchanges, interviews, structured conversations", "conversation",
                [
                    "short_summary": ["type": "string"],
                    "exchanges": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "speaker": ["type": "string"], "question": ["type": "string"],
                                "answer": ["type": "string"], "follow_ups": ["type": "array", "items": ["type": "string"]],
                            ],
                        ],
                    ],
                    "key_takeaways": ["type": "array", "items": ["type": "string"]],
                    "unanswered_questions": ["type": "array", "items": ["type": "string"]],
                    "participants": ["type": "array", "items": ["type": "string"]],
                ]
            ),
            (
                "people_tracker", "People Tracker", "Attendees, commitments, sentiment, accountability", "meeting",
                [
                    "short_summary": ["type": "string"],
                    "attendees": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"], "role": ["type": "string"], "present": ["type": "boolean"],
                            ],
                        ],
                    ],
                    "commitments": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "who": ["type": "string"], "what": ["type": "string"],
                                "deadline": ["type": "string"], "status": ["type": "string", "enum": ["pending", "done", "overdue"]],
                            ],
                        ],
                    ],
                    "sentiment": [
                        "type": "object",
                        "properties": [
                            "overall": ["type": "string", "enum": ["positive", "neutral", "negative", "mixed"]],
                            "notes": ["type": "string"],
                        ],
                    ],
                    "notable_contributions": ["type": "array", "items": ["type": "string"]],
                ]
            ),
            (
                "research_synthesis", "Research Synthesis", "Hypotheses, findings, sources, methodology", "research",
                [
                    "short_summary": ["type": "string"],
                    "hypotheses": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "statement": ["type": "string"], "confidence": ["type": "string", "enum": ["high", "medium", "low", "speculative"]],
                                "evidence_for": ["type": "string"], "evidence_against": ["type": "string"],
                            ],
                        ],
                    ],
                    "findings": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "description": ["type": "string"], "source": ["type": "string"],
                                "strength": ["type": "string", "enum": ["strong", "moderate", "weak"]],
                            ],
                        ],
                    ],
                    "methodology_notes": ["type": "string"],
                    "limitations": ["type": "array", "items": ["type": "string"]],
                    "references": ["type": "array", "items": ["type": "string"]],
                ]
            ),
            (
                "timeline_narrative", "Timeline Narrative", "Chronological events, cause-effect chains", "analysis",
                [
                    "short_summary": ["type": "string"],
                    "events": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "timestamp": ["type": "string"], "description": ["type": "string"],
                                "speaker": ["type": "string"],
                                "cause_of": ["type": "array", "items": ["type": "string"]],
                                "caused_by": ["type": "array", "items": ["type": "string"]],
                            ],
                        ],
                    ],
                    "turning_points": ["type": "array", "items": ["type": "string"]],
                    "timeline_summary": ["type": "string"],
                ]
            ),
            (
                "journal_personal", "Journal / Personal", "Personal reflection, mood, people, places, themes", "personal",
                [
                    "short_summary": ["type": "string"],
                    "themes": ["type": "array", "items": ["type": "string"]],
                    "mood_indicators": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mood": ["type": "string"], "intensity": ["type": "string", "enum": ["high", "medium", "low"]],
                                "trigger": ["type": "string"],
                            ],
                        ],
                    ],
                    "people_mentioned": ["type": "array", "items": ["type": "string"]],
                    "places": ["type": "array", "items": ["type": "string"]],
                    "cross_references": ["type": "array", "items": ["type": "string"]],
                ]
            ),
            (
                "knowledge_extraction", "Knowledge Extraction", "Key points, entities, relationships — for notes, articles", "general",
                [
                    "short_summary": ["type": "string"],
                    "key_points": ["type": "array", "items": ["type": "string"]],
                    "entities": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"],
                                "type": ["type": "string", "enum": ["person", "organization", "tool", "concept", "place", "event"]],
                            ],
                        ],
                    ],
                    "relationships": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "from": ["type": "string"], "to": ["type": "string"], "relationship": ["type": "string"],
                            ],
                        ],
                    ],
                    "source_type": ["type": "string"],
                    "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                ]
            ),
        ]

        var dict: [String: AnalysisSchema] = [:]
        let decoder = JSONDecoder()
        for (name, displayName, description, category, props) in raw {
            let schemaDict: [String: Any] = [
                "name": name, "displayName": displayName, "description": description,
                "category": category, "outputSchema": ["properties": props, "required": ["short_summary"]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: schemaDict),
                let schema = try? decoder.decode(AnalysisSchema.self, from: data)
            else { continue }
            dict[name] = schema
        }
        return dict
    }
}

// MARK: - Select Schema Tool

struct SelectSchemaTool: AgentTool {
    let name = "select_schema"
    let description: String
    let parameters = AIToolParameters(
        properties: ["schema_name": AIToolProperty(type: "string", description: "Name of the schema to use (from catalog).")],
        required: ["schema_name"]
    )

    @MainActor init() {
        let catalog = AnalysisSchemaStore.shared.catalog()
        description = """
            Select the output schema (structure + required fields).
            ## Available Schemas
            \(catalog)
            Choose the schema that best matches the content. MUST call before write_analysis.
            """
    }

    @MainActor func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let name = arguments["schema_name"] as? String else {
            return ToolResult(content: "Error: schema_name required", isError: true, displaySummary: "Missing")
        }
        guard let schema = AnalysisSchemaStore.shared.schema(named: name) else {
            return ToolResult(content: "Schema '\(name)' not found.\n\n\(AnalysisSchemaStore.shared.catalog())", isError: true, displaySummary: "Unknown")
        }
        context.activeSchema = schema
        let req = schema.outputSchema.required?.joined(separator: ", ") ?? "none"
        let fields = schema.outputSchema.properties.keys.sorted().joined(separator: ", ")
        return ToolResult(content: "Schema: \(schema.displayName)\nRequired: \(req)\nFields: \(fields)", displaySummary: "Schema: \(schema.displayName)")
    }
}

// MARK: - Select Skill Tool

struct SelectSkillTool: AgentTool {
    let name = "select_skill"
    let description: String
    let parameters = AIToolParameters(
        properties: ["skill_name": AIToolProperty(type: "string", description: "Name of the skill to use (from catalog).")],
        required: ["skill_name"]
    )

    @MainActor init() {
        let skills = AnalysisSkillStore.shared.skills.values.sorted { $0.displayName < $1.displayName }
        description = """
            Select the analysis skill (tutorial/procedure).
            ## Available Skills
            \(skills.map { "\($0.name) — \($0.displayName): \($0.description)" }.joined(separator: "\n"))
            Choose the skill that best guides how to analyze this content. MUST call before analyzing.
            """
    }

    @MainActor func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let name = arguments["skill_name"] as? String else {
            return ToolResult(content: "Error: skill_name required", isError: true, displaySummary: "Missing")
        }
        guard let skill = AnalysisSkillStore.shared.skill(named: name) else {
            let avail = AnalysisSkillStore.shared.skills.values.sorted { $0.displayName < $1.displayName }
                .map { "\($0.name) — \($0.displayName)" }.joined(separator: "\n")
            return ToolResult(content: "Skill '\(name)' not found.\n\nAvailable:\n\(avail)", isError: true, displaySummary: "Unknown")
        }
        var r = "Skill: \(skill.displayName)\nDescription: \(skill.description)\n\n"
        if let proc = skill.procedure, !proc.steps.isEmpty {
            r += "## PROCEDURE\n"
            for s in proc.steps.sorted(by: { $0.step < $1.step }) {
                r += "Step \(s.step): \(s.action) — \(s.description)\n"
            }
        }
        r += "\n## GUIDANCE\n\(skill.systemPrompt)"
        return ToolResult(content: r, displaySummary: "Skill: \(skill.displayName)")
    }
}

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
            ),
        ],
        required: ["itemId", "analysisJson"]
    )

    /// Maximum allowed size for analysis JSON in bytes (1 MB).
    /// Larger payloads are rejected to prevent runaway LLM output from
    /// filling the disk with repetitive or hallucinated content.
    private static let maxAnalysisSize = 1_048_576  // 1 MB

    @MainActor
    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let itemIdStr = arguments["itemId"] as? String,
            let itemId = UUID(uuidString: itemIdStr)
        else {
            let raw = String(describing: arguments["itemId"])
            AppLog.provider.error("write_analysis: invalid itemId '\(raw)'")
            return ToolResult(
                content: "Error: itemId must be a valid UUID. Received: \(raw)",
                isError: true, displaySummary: "Invalid itemId")
        }

        guard let jsonStr = arguments["analysisJson"] as? String else {
            AppLog.provider.error("write_analysis: missing analysisJson")
            return ToolResult(
                content: "Error: analysisJson is required",
                isError: true, displaySummary: "Missing JSON")
        }

        // Reject oversized payloads before any file I/O
        guard jsonStr.utf8.count <= Self.maxAnalysisSize else {
            let sizeMB = Double(jsonStr.utf8.count) / 1_048_576.0
            AppLog.provider.error("write_analysis: analysisJson too large — \(String(format: "%.1f", sizeMB)) MB (max 1 MB)")
            return ToolResult(
                content: "Error: analysisJson exceeds 1 MB maximum. Please reduce the content size.",
                isError: true, displaySummary: "Content too large")
        }

        // Validate JSON structure
        guard let data = jsonStr.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            !json.isEmpty
        else {
            let preview = String(jsonStr.prefix(200))
            AppLog.provider.error("write_analysis: invalid JSON: \(preview)")
            return ToolResult(
                content: "Error: analysisJson is not valid JSON. Check for unescaped quotes, trailing commas, or missing braces. First 200 chars: \(preview)",
                isError: true, displaySummary: "Invalid JSON")
        }

        // Add provenance metadata so consumers know who wrote this and when
        var enrichedJSON = json
        enrichedJSON["_metadata"] = [
            "writtenBy": "WriteAnalysisTool",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sectionCount": json.count,
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
                abs(verifyData.count - prettyData.count) <= 1
            else {
                AppLog.provider.error("write_analysis: read-back verification failed — size mismatch")
                return ToolResult(
                    content: "Error: analysis write verification failed — the file may be corrupted. Please retry.",
                    isError: true, displaySummary: "Write verification failed")
            }

            AppLog.provider.info("write_analysis: saved \(json.count) sections (\(prettyData.count) bytes) to \(url.path)")

            // ── Framework schema validation ──────────────────────────
            // If a framework or schema is active, validate the output and return
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
            } else if let schema = context.activeSchema {
                let errors = Self.validateJSON(json, against: schema)
                if let errors {
                    let errorList = errors.joined(separator: "\n").prefix(5)
                    let reqFields = schema.outputSchema.required?.joined(separator: ", ") ?? "none"
                    validationNote = """

                        ⚠️ SCHEMA VALIDATION ISSUES (fix and call write_analysis again):
                        Schema: \(schema.displayName)
                        \(String(errorList))

                        Required fields: \(reqFields)
                        All fields: \(schema.outputSchema.properties.keys.sorted().joined(separator: ", "))

                        Fix your analysis JSON to include all required fields with correct types, then call write_analysis again.
                        """
                    AppLog.provider.warning("write_analysis: schema validation failed — \(schema.name)")
                } else {
                    AppLog.provider.info("write_analysis: schema validation passed — \(schema.name)")
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
            return ToolResult(
                content: "Error writing analysis: \(error.localizedDescription)",
                isError: true, displaySummary: "Write failed")
        }
    }

    /// Validates a JSON object against an AnalysisSchema. Returns an array of
    /// error strings, or nil if valid. Checks required fields and basic type matching.
    static func validateJSON(_ json: [String: Any], against schema: AnalysisSchema) -> [String]? {
        var errors: [String] = []
        let props = schema.outputSchema.properties
        let schemaMeta = json["_metadata"] as? [String: Any]

        // Required fields
        if let required = schema.outputSchema.required {
            for field in required {
                if json[field] == nil {
                    errors.append("Missing required field: '\(field)'")
                }
            }
        }

        // Type checks on present fields
        for (key, value) in json where key != "_metadata" {
            guard let prop = props[key] else {
                errors.append("Unknown field '\(key)' — not in schema. Available fields: \(props.keys.sorted().joined(separator: ", "))")
                continue
            }
            switch prop.type {
            case "string":
                if !(value is String) { errors.append("'\(key)' must be a string") }
            case "array":
                if !(value is [Any]) { errors.append("'\(key)' must be an array") }
            case "object":
                if !(value is [String: Any]) { errors.append("'\(key)' must be an object") }
            default:
                break
            }
        }

        return errors.isEmpty ? nil : errors
    }
}

// MARK: - Write Speakers Tool

/// Dedicated tool for speaker resolution output. The agent identifies speakers
/// from the transcript, cross-references with contacts/calendar/memory via the
/// `person` command, and writes structured results. Schema is strictly validated
/// — the agent retries until it passes.
struct WriteSpeakersTool: AgentTool {
    let name = "write_speakers"
    let description = """
        Write the speaker resolution results after cross-referencing with \
        contacts, calendar, and transcripts. Call this AFTER using `person` \
        to research each speaker. The output is validated against a strict \
        schema — fix any validation errors and call again.
        """
    let parameters = AIToolParameters(
        properties: [
            "speakersJson": AIToolProperty(
                type: "string",
                description: "JSON with 'speakers' array and optional 'pending_confirmations' array."
            )
        ],
        required: ["speakersJson"]
    )

    @MainActor
    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let jsonStr = arguments["speakersJson"] as? String,
            let data = jsonStr.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ToolResult(content: "Error: speakersJson must be valid JSON", isError: true, displaySummary: "Invalid JSON")
        }

        // Validate against strict schema
        if let errors = validateSpeakersSchema(json) {
            return ToolResult(
                content: """
                    ⚠️ SCHEMA VALIDATION FAILED — fix and call write_speakers again:

                    \(errors.joined(separator: "\n"))

                    Required format:
                    {
                      "speakers": [{
                        "label": "Speaker 1",
                        "resolved_to": "Full Name",
                        "confidence": "high|medium|low",
                        "evidence_summary": "1-2 sentence summary"
                      }],
                      "pending_confirmations": [{
                        "speaker_label": "Speaker 3",
                        "best_guess": "Full Name",
                        "confidence": "low",
                        "candidates": [{"name": "...", "evidence": "..."}],
                        "question": "Who is this?"
                      }]
                    }
                    """, isError: true, displaySummary: "Schema validation failed")
        }

        // Write speakers.json artifact
        guard let itemID = context.activeItemID else {
            return ToolResult(content: "Error: no active item in context", isError: true, displaySummary: "No item")
        }
        let store = FileArtifactStore()
        try store.createMeetingDirectory(for: itemID)
        let enriched = json.merging(["_metadata": ["writtenBy": "WriteSpeakersTool", "timestamp": ISO8601DateFormatter().string(from: Date())]]) { $1 }
        let prettyData = try JSONSerialization.data(withJSONObject: enriched, options: [.prettyPrinted, .sortedKeys])
        let url = store.itemDirectoryURL(for: itemID).appendingPathComponent("speakers.json")
        try store.atomicWriteWithBackup(data: prettyData, url: url)

        let speakerCount = (json["speakers"] as? [[String: Any]])?.count ?? 0
        let pendingCount = (json["pending_confirmations"] as? [[String: Any]])?.count ?? 0
        return ToolResult(
            content: "Speakers written: \(speakerCount) resolved, \(pendingCount) pending confirmation.",
            displaySummary: "\(speakerCount) speakers, \(pendingCount) pending")
    }

    /// Validates the speakers JSON against the strict schema. Returns array of
    /// error strings or nil if valid.
    private func validateSpeakersSchema(_ json: [String: Any]) -> [String]? {
        var errors: [String] = []

        guard let speakers = json["speakers"] as? [[String: Any]], !speakers.isEmpty else {
            return ["Missing required 'speakers' array (must be non-empty)"]
        }

        for (i, sp) in speakers.enumerated() {
            let prefix = "speakers[\(i)]"
            if sp["label"] as? String == nil { errors.append("\(prefix).label: required string") }
            if sp["resolved_to"] as? String == nil { errors.append("\(prefix).resolved_to: required string") }
            if let conf = sp["confidence"] as? String, !["high", "medium", "low"].contains(conf) {
                errors.append("\(prefix).confidence: must be high|medium|low, got '\(conf)'")
            } else if sp["confidence"] == nil {
                errors.append("\(prefix).confidence: required (high|medium|low)")
            }
            if sp["evidence_summary"] as? String == nil { errors.append("\(prefix).evidence_summary: required string") }
        }

        if let pending = json["pending_confirmations"] as? [[String: Any]] {
            for (i, pc) in pending.enumerated() {
                let prefix = "pending_confirmations[\(i)]"
                if pc["speaker_label"] as? String == nil { errors.append("\(prefix).speaker_label: required") }
                if pc["best_guess"] as? String == nil { errors.append("\(prefix).best_guess: required") }
                if let conf = pc["confidence"] as? String, !["high", "medium", "low"].contains(conf) {
                    errors.append("\(prefix).confidence: must be high|medium|low")
                }
                guard let candidates = pc["candidates"] as? [[String: Any]], !candidates.isEmpty else {
                    errors.append("\(prefix).candidates: required non-empty array")
                    continue
                }
                for (j, c) in candidates.enumerated() {
                    if c["name"] as? String == nil { errors.append("\(prefix).candidates[\(j)].name: required") }
                    if c["evidence"] as? String == nil { errors.append("\(prefix).candidates[\(j)].evidence: required") }
                }
                if pc["question"] as? String == nil { errors.append("\(prefix).question: required") }
            }
        }

        return errors.isEmpty ? nil : errors
    }
}

// MARK: - Set Title Tool

/// Dedicated tool for the agent to rename an item after reading its content.
/// Called BEFORE analysis so the title reflects what the content is actually about,
/// not the original filename or recording date.
struct SetTitleTool: AgentTool {
    let name = "set_title"
    let description = """
        Set a descriptive title for this item after reading its content.
        Call this BEFORE write_analysis — read the content first, then
        generate a concise title (5-10 words) that captures the essence.
        Better than generic names like "Recording 2026-06-15".
        """
    let parameters = AIToolParameters(
        properties: [
            "title": AIToolProperty(
                type: "string",
                description: "The new title (5-10 words, descriptive, no quotes needed)"
            )
        ],
        required: ["title"]
    )

    @MainActor
    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let newTitle = arguments["title"] as? String,
            !newTitle.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return ToolResult(
                content: "Error: title is required and must be non-empty",
                isError: true, displaySummary: "Missing title")
        }
        guard let itemID = context.activeItemID else {
            return ToolResult(
                content: "Error: no active item in context",
                isError: true, displaySummary: "No item")
        }

        let fetch = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemID })
        guard let item = try? context.modelContext.fetch(fetch).first else {
            return ToolResult(
                content: "Error: item \(itemID) not found",
                isError: true, displaySummary: "Not found")
        }

        if item.originalTitle == nil {
            item.originalTitle = item.title
        }
        item.title = newTitle
        try? context.modelContext.save()
        AppLog.provider.info("set_title: \"\(newTitle)\" (was: \"\(item.originalTitle ?? "")\")")
        return ToolResult(content: "Title set to: \(newTitle)", displaySummary: "Renamed")
    }
}
