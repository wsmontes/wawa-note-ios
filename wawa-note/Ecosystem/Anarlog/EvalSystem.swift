import Foundation
import OSLog

// Related JIRA: KAN-13, KAN-69

// MARK: - LLM Output Evaluation System

/// Validates LLM outputs against expected schemas and quality criteria.
///
/// Inspired by anarlog's `template-eval` crate (automated template evaluation)
/// but implemented as a pure Swift validation engine.
///
/// Validation dimensions:
/// 1. **Schema compliance** — does the JSON match the expected structure?
/// 2. **Field presence** — are required fields present?
/// 3. **Value reasonableness** — do values make sense (non-empty, valid types)?
/// 4. **Content quality** — heuristics for hallucination detection
///
/// Used after ContentPipeline analysis to catch bad LLM outputs before
/// they contaminate the knowledge base.
struct EvalSystem {
    private let logger = Logger(subsystem: "com.wawa.note", category: "EvalSystem")

    // MARK: - Evaluation Result

    struct EvalResult: Codable {
        let score: Int  // 0-100
        let status: EvalStatus
        let checks: [EvalCheck]
        let errors: [EvalError]
        let summary: String

        var isPassing: Bool { status == .pass || status == .warn }
    }

    enum EvalStatus: String, Codable {
        case pass  // 80-100: all checks OK
        case warn  // 60-79: minor issues, acceptable
        case fail  // 0-59: major issues, reject
        case error  // couldn't evaluate (invalid JSON, etc.)
    }

    struct EvalCheck: Codable, Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let score: Int  // 0-100 for this check
        let detail: String?
    }

    struct EvalError: Codable, Identifiable {
        var id: String { "\(field)_\(rule)" }
        let field: String
        let rule: String
        let message: String
        let severity: ErrorSeverity
    }

    enum ErrorSeverity: String, Codable {
        case critical  // Must fix — makes output unusable
        case major  // Should fix — degrades quality
        case minor  // Nice to fix — cosmetic
    }

    // MARK: - Schema Definition

    /// Expected schema for LLM output validation.
    struct ExpectedSchema {
        struct Field {
            let name: String
            let type: FieldType
            let required: Bool
            let minItems: Int?
            let maxLength: Int?
            let allowedValues: [String]?
        }

        enum FieldType: String {
            case string, number, boolean, array, object, date
        }

        let fields: [Field]
        let requiredFields: [String]

        init(fields: [Field]) {
            self.fields = fields
            self.requiredFields = fields.filter(\.required).map(\.name)
        }
    }

    // MARK: - Predefined schemas

    /// Meeting analysis schema (matches our FrameworkService.meetingFramework).
    static let meetingSchema = ExpectedSchema(fields: [
        ExpectedSchema.Field(name: "short_summary", type: .string, required: true, minItems: nil, maxLength: 500, allowedValues: nil),
        ExpectedSchema.Field(name: "detailed_summary", type: .string, required: false, minItems: nil, maxLength: 5000, allowedValues: nil),
        ExpectedSchema.Field(name: "decisions", type: .array, required: false, minItems: nil, maxLength: nil, allowedValues: nil),
        ExpectedSchema.Field(name: "action_items", type: .array, required: false, minItems: nil, maxLength: nil, allowedValues: nil),
        ExpectedSchema.Field(name: "risks", type: .array, required: false, minItems: nil, maxLength: nil, allowedValues: nil),
        ExpectedSchema.Field(name: "open_questions", type: .array, required: false, minItems: nil, maxLength: nil, allowedValues: nil),
        ExpectedSchema.Field(name: "entities", type: .array, required: false, minItems: nil, maxLength: nil, allowedValues: nil),
    ])

    // MARK: - Schema Validation

    /// Validate JSON data against an expected schema.
    func validateSchema(_ jsonData: Data, against schema: ExpectedSchema) -> EvalResult {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return EvalResult(
                score: 0, status: .error, checks: [],
                errors: [
                    EvalError(
                        field: "root", rule: "valid_json",
                        message: "Output is not valid JSON", severity: .critical)
                ],
                summary: "Invalid JSON — cannot evaluate"
            )
        }

        var checks: [EvalCheck] = []
        var errors: [EvalError] = []
        var totalScore = 0
        let maxScore = schema.fields.count * 100

        for field in schema.fields {
            let value = json[field.name]
            let (passed, fieldScore, fieldErrors) = validateField(field, value: value)
            checks.append(EvalCheck(name: field.name, passed: passed, score: fieldScore, detail: nil))
            errors.append(contentsOf: fieldErrors)
            totalScore += fieldScore
        }

        let score = maxScore > 0 ? (totalScore * 100) / maxScore : 100
        let status: EvalStatus = score >= 80 ? .pass : score >= 60 ? .warn : .fail

        return EvalResult(
            score: score,
            status: status,
            checks: checks,
            errors: errors,
            summary: "Schema validation: \(score)/100 — \(errors.count) issue(s)"
        )
    }

    private func validateField(_ field: ExpectedSchema.Field, value: Any?) -> (Bool, Int, [EvalError]) {
        var errors: [EvalError] = []
        var score = 100

        // Required check
        if field.required && (value == nil || value is NSNull) {
            errors.append(
                EvalError(
                    field: field.name, rule: "required",
                    message: "Required field '\(field.name)' is missing",
                    severity: .critical
                ))
            return (false, 0, errors)
        }

        guard let value = value, !(value is NSNull) else {
            return (true, 100, [])  // Optional field, not present — OK
        }

        // Type check
        switch field.type {
        case .string:
            guard let str = value as? String else {
                errors.append(
                    EvalError(
                        field: field.name, rule: "type",
                        message: "'\(field.name)' must be a string", severity: .critical))
                return (false, 0, errors)
            }
            // Check not empty
            if field.required && str.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append(
                    EvalError(
                        field: field.name, rule: "non_empty",
                        message: "'\(field.name)' is empty", severity: .major))
                score -= 40
            }
            // Check max length
            if let maxLen = field.maxLength, str.count > maxLen {
                errors.append(
                    EvalError(
                        field: field.name, rule: "max_length",
                        message: "'\(field.name)' exceeds max length (\(maxLen))", severity: .minor))
                score -= 20
            }

        case .number:
            if !(value is NSNumber) && !(value is Int) && !(value is Double) {
                errors.append(
                    EvalError(
                        field: field.name, rule: "type",
                        message: "'\(field.name)' must be a number", severity: .critical))
                return (false, 0, errors)
            }

        case .boolean:
            if !(value is Bool) {
                errors.append(
                    EvalError(
                        field: field.name, rule: "type",
                        message: "'\(field.name)' must be a boolean", severity: .critical))
                return (false, 0, errors)
            }

        case .array:
            guard let arr = value as? [Any] else {
                errors.append(
                    EvalError(
                        field: field.name, rule: "type",
                        message: "'\(field.name)' must be an array", severity: .critical))
                return (false, 0, errors)
            }
            if let minItems = field.minItems, arr.count < minItems {
                errors.append(
                    EvalError(
                        field: field.name, rule: "min_items",
                        message: "'\(field.name)' has \(arr.count) items, min \(minItems)", severity: .major))
                score -= 30
            }

        case .object:
            if !(value is [String: Any]) {
                errors.append(
                    EvalError(
                        field: field.name, rule: "type",
                        message: "'\(field.name)' must be an object", severity: .critical))
                return (false, 0, errors)
            }

        case .date:
            if let dateStr = value as? String {
                if ISO8601DateFormatter().date(from: dateStr) == nil {
                    errors.append(
                        EvalError(
                            field: field.name, rule: "date_format",
                            message: "'\(field.name)' is not a valid ISO 8601 date", severity: .minor))
                    score -= 10
                }
            }
        }

        return (errors.isEmpty, score, errors)
    }

    // MARK: - Content Quality Heuristics

    /// Check for common LLM hallucination patterns.
    func checkHallucinations(in text: String) -> [EvalError] {
        var errors: [EvalError] = []

        // Check for common hallucination markers
        let lowercased = text.lowercased()

        // "As an AI" / "I am a language model" — model identity leak
        if lowercased.contains("as an ai") || lowercased.contains("as a language model") {
            errors.append(
                EvalError(
                    field: "content", rule: "no_self_reference",
                    message: "Output contains AI self-reference — likely hallucinated preamble",
                    severity: .major))
        }

        // Placeholder patterns
        if lowercased.contains("[insert") || lowercased.contains("[todo]") || lowercased.contains("[placeholder") {
            errors.append(
                EvalError(
                    field: "content", rule: "no_placeholders",
                    message: "Output contains placeholder text",
                    severity: .major))
        }

        // Excessive repetition (>3 identical consecutive lines)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var repeatCount = 1
        for i in 1..<lines.count where !lines[i].isEmpty {
            if lines[i] == lines[i - 1] {
                repeatCount += 1
            } else {
                repeatCount = 1
            }
            if repeatCount > 3 {
                errors.append(
                    EvalError(
                        field: "content", rule: "no_repetition",
                        message: "Output contains repetitive content (line repeated \(repeatCount)x)",
                        severity: .minor))
                break
            }
        }

        return errors
    }

    /// Validate analysis JSON for completeness and reasonableness.
    func validateAnalysis(_ json: [String: Any]) -> EvalResult {
        var errors: [EvalError] = []
        var checks: [EvalCheck] = []

        // Check short_summary presence and quality
        if let summary = json["short_summary"] as? String {
            let wordCount = summary.components(separatedBy: " ").count
            let passed = wordCount >= 3 && wordCount <= 50
            checks.append(
                EvalCheck(
                    name: "short_summary", passed: passed, score: passed ? 100 : 50,
                    detail: "\(wordCount) words"))
            if !passed {
                errors.append(
                    EvalError(
                        field: "short_summary", rule: "length",
                        message: "Summary has \(wordCount) words (expected 3-50)", severity: .minor))
            }
        } else {
            checks.append(EvalCheck(name: "short_summary", passed: false, score: 0, detail: "missing"))
            errors.append(
                EvalError(
                    field: "short_summary", rule: "required",
                    message: "short_summary is required", severity: .critical))
        }

        // Check decisions have titles
        if let decisions = json["decisions"] as? [[String: Any]] {
            let withTitles = decisions.filter { ($0["title"] as? String)?.isEmpty == false }.count
            let passed = withTitles == decisions.count
            checks.append(
                EvalCheck(
                    name: "decisions", passed: passed, score: passed ? 100 : 60,
                    detail: "\(withTitles)/\(decisions.count) have titles"))
            if !passed {
                errors.append(
                    EvalError(
                        field: "decisions", rule: "items_have_titles",
                        message: "\(decisions.count - withTitles) decisions missing titles", severity: .major))
            }
        }

        // Check action items have tasks
        if let actions = json["action_items"] as? [[String: Any]] {
            let withTasks = actions.filter { ($0["task"] as? String)?.isEmpty == false }.count
            let passed = withTasks == actions.count
            checks.append(
                EvalCheck(
                    name: "action_items", passed: passed, score: passed ? 100 : 50,
                    detail: "\(withTasks)/\(actions.count) have tasks"))
            if !passed {
                errors.append(
                    EvalError(
                        field: "action_items", rule: "items_have_tasks",
                        message: "\(actions.count - withTasks) action items missing task descriptions", severity: .major))
            }
        }

        let totalScore = checks.map(\.score).reduce(0, +) / max(checks.count, 1)
        let status: EvalStatus = totalScore >= 80 ? .pass : totalScore >= 60 ? .warn : .fail

        return EvalResult(
            score: totalScore,
            status: status,
            checks: checks,
            errors: errors,
            summary: "Analysis quality: \(totalScore)/100 — \(errors.count) issue(s)"
        )
    }

    // MARK: - Full evaluation pipeline

    /// Run full evaluation on a content analysis output.
    /// Returns nil if the output is fatally flawed (score < 60).
    func evaluate(_ jsonData: Data, schema: ExpectedSchema = meetingSchema) -> EvalResult? {
        let schemaResult = validateSchema(jsonData, against: schema)

        // If schema validation fails critically, reject immediately
        if schemaResult.status == .error || schemaResult.status == .fail {
            logger.warning("Eval failed: \(schemaResult.summary)")
            return schemaResult
        }

        // Content quality checks on relevant text fields
        var allErrors = schemaResult.errors
        if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let analysisResult = validateAnalysis(json)
            allErrors.append(contentsOf: analysisResult.errors)

            // Check hallucinations in text content
            if let summary = json["short_summary"] as? String {
                allErrors.append(contentsOf: checkHallucinations(in: summary))
            }
            if let detailed = json["detailed_summary"] as? String {
                allErrors.append(contentsOf: checkHallucinations(in: detailed))
            }
        }

        let finalScore: Int
        if schemaResult.errors.isEmpty && allErrors.isEmpty {
            finalScore = 100
        } else {
            let criticalCount = allErrors.filter { $0.severity == .critical }.count
            let majorCount = allErrors.filter { $0.severity == .major }.count
            finalScore = max(0, 100 - criticalCount * 30 - majorCount * 10)
        }

        let status: EvalStatus = finalScore >= 80 ? .pass : finalScore >= 60 ? .warn : .fail

        return EvalResult(
            score: finalScore,
            status: status,
            checks: schemaResult.checks,
            errors: allErrors,
            summary: "Evaluation: \(finalScore)/100 — \(allErrors.count) issue(s) (\(status.rawValue))"
        )
    }
}

// MARK: - Content Pipeline Integration

extension EvalSystem {
    /// Validate analysis.json produced by the ContentPipeline agent.
    /// Called after the agent finishes, before marking the item as analyzed.
    static func validatePipelineOutput(itemID: UUID, fileStore: FileArtifactStore) -> Bool {
        let eval = EvalSystem()
        let analysisURL = fileStore.itemDirectoryURL(for: itemID).appendingPathComponent("analysis.json")

        guard let data = try? Data(contentsOf: analysisURL) else {
            return false  // No analysis produced = failure
        }

        let result = eval.evaluate(data)
        return result?.isPassing ?? false
    }
}
