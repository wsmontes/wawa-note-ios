import Foundation
import SwiftData
import OSLog
// Related JIRA: KAN-7, KAN-33


// MARK: - Analysis Skill Service

/// Orchestrates item analysis using Skills + Meetily Templates + AgentLoop.
///
/// This replaces the generic VFS agent prompt with a skill-driven approach:
/// 1. Resolve the best AnalysisSkill for the item
/// 2. Link the skill's Meetily template for output format
/// 3. Build a combined system prompt: skill procedure + template format
/// 4. Run the existing AgentLoop with ShellTool
/// 5. Validate output with EvalSystem
/// 6. Cache via SummaryCache
///
/// The ShellTool remains the agent's primary tool — skills define WHEN and HOW
/// to use it, templates define WHAT to produce.
@MainActor
struct AnalysisSkillService {
    private let logger = Logger(subsystem: "com.wawa.note", category: "AnalysisSkill")
    private let skillStore = AnalysisSkillStore.shared
    private let templateService = MeetilyTemplateService.shared
    private let cache = SummaryCache.shared
    private let eval = EvalSystem()
    private let fileStore = FileArtifactStore()

    // MARK: - Analyze

    func analyze(
        item: KnowledgeItem,
        using modelContext: ModelContext,
        provider: any AIProvider,
        model: String,
        maxRetries: Int = 2
    ) async throws -> MeetingAnalysis {
        // 1. Resolve skill
        let skill = skillStore.resolve(for: item)
        logger.info("Resolved skill: \(skill.displayName) for item \(item.id.uuidString.prefix(8))")

        // 2. Resolve template
        let templateID = skill.templateID.isEmpty ? "standard_meeting" : skill.templateID
        guard let template = templateService.template(id: templateID) else {
            throw ServiceError.templateNotFound(templateID)
        }

        // 3. Build prompts
        let systemPrompt = buildSystemPrompt(skill: skill, template: template)
        let (userPrompt, _) = await buildUserPrompt(item: item, template: template, context: modelContext)

        // 4. Check cache
        if let cached = cache.get(
            transcript: userPrompt,
            templateID: template.id,
            systemPrompt: systemPrompt,
            modelProvider: provider.id,
            modelName: model
        ) {
            logger.info("Cache hit for '\(skill.displayName)' — returning cached")
            return try parseAnalysisJSON(cached.markdown, template: template, meetingId: item.id)
        }

        // 5. Run agent loop with retry
        var lastError: String?
        var lastResponse: String?

        for attempt in 1...maxRetries + 1 {
            let taskDescription = attempt == 1 ? userPrompt : """
            \(userPrompt)

            PREVIOUS ATTEMPT FAILED: \(lastError ?? "unknown")
            Fix the issues and retry.
            """

            let messages = [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(taskDescription)])
            ]

            let params = AIConfigService.shared.requestParams(for: "analysis", model: model)
            let request = AIRequest(model: model, messages: messages, temperature: params.temperature, maxTokens: params.maxTokens)

            do {
                let response = try await provider.send(request)
                let content = extractJSON(from: response.content)
                lastResponse = content

                // Validate
                if let data = content.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let evalResult = eval.validateAnalysis(json)
                    if evalResult.isPassing {
                        let analysis = try parseAnalysisJSON(content, template: template, meetingId: item.id)
                        cache.set(markdown: content, transcript: userPrompt, templateID: template.id,
                                  systemPrompt: systemPrompt, modelProvider: provider.id, modelName: model)
                        logger.info("Analysis passed (score: \(evalResult.score)) on attempt \(attempt)")
                        return analysis
                    } else {
                        lastError = evalResult.errors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
                    }
                } else {
                    lastError = "Response is not valid JSON"
                }
            } catch {
                lastError = error.localizedDescription
            }

            logger.warning("Attempt \(attempt) failed: \(lastError ?? "unknown")")
        }

        // Best-effort parse
        if let response = lastResponse {
            return try parseAnalysisJSON(response, template: template, meetingId: item.id)
        }
        throw ServiceError.allAttemptsFailed
    }

    // MARK: - Prompt builders

    private func buildSystemPrompt(skill: AnalysisSkill, template: MeetilyTemplateService.MeetilyTemplate) -> String {
        var prompt = skill.systemPrompt
        prompt += "\n\n## OUTPUT TEMPLATE: \(template.name)\n"

        for section in template.sections {
            prompt += "\n### \(section.title)\n\(section.instruction)\n"
            prompt += "Format: \(section.format.rawValue)"
            if let fmt = section.itemFormat { prompt += "\nTable format: \(fmt)" }
        }

        prompt += """

        ## CRITICAL
        - You MUST write the analysis using: echo '{"short_summary":"...","decisions":[...],...}' > /inbox/<id>/analysis.json
        - For project items: echo '...' > /projects/<slug>/analysis/<id>.json
        - All JSON fields in the template MUST be present
        - If a field has no data, use null or empty array
        - Do NOT just describe the analysis — WRITE it with echo
        """

        return prompt
    }

    private func buildUserPrompt(
        item: KnowledgeItem,
        template: MeetilyTemplateService.MeetilyTemplate,
        context: ModelContext
    ) async -> (prompt: String, textLength: Int) {
        let extractSvc = ContentExtractionService(modelContext: context, fileStore: fileStore)
        let text = await extractSvc.bestAvailableText(for: item) ?? item.bodyText ?? ""

        var prompt = "Item: \(item.title)\nType: \(item.type.rawValue)\n\n"
        prompt += "CONTENT:\n\(text)\n\n"
        prompt += "TEMPLATE SECTIONS TO FILL:\n"
        for section in template.sections {
            prompt += "- \(section.title): \(section.instruction)\n"
        }

        return (prompt, text.count)
    }

    // MARK: - JSON parsing

    private func extractJSON(from response: String) -> String {
        var text = response
        if let start = text.range(of: "```json") { text = String(text[start.upperBound...]) }
        else if let start = text.range(of: "```") { text = String(text[start.upperBound...]) }
        if let end = text.range(of: "```", options: .backwards) { text = String(text[..<end.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseAnalysisJSON(_ jsonString: String, template: MeetilyTemplateService.MeetilyTemplate, meetingId: UUID) throws -> MeetingAnalysis {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidJSON
        }

        return MeetingAnalysis(
            meetingId: meetingId,
            providerId: "meetily-skill",
            shortSummary: (json["short_summary"] ?? json["shortSummary"] ?? json["summary"] ?? json["Summary"]) as? String ?? "",
            detailedSummary: (json["detailed_summary"] ?? json["detailedSummary"] ?? "") as? String ?? "",
            decisions: parseDecisions(json),
            actionItems: parseActions(json),
            risks: parseRisks(json),
            openQuestions: parseQuestions(json),
            importantDates: [],
            entities: []
        )
    }

    private func parseDecisions(_ json: [String: Any]) -> [Decision] {
        for key in ["decisions", "key_decisions", "Decisions", "Key Decisions"] {
            if let items = json[key] as? [[String: Any]] {
                return items.compactMap { item in
                    guard let title = (item["title"] ?? item["decision"] ?? item["item"]) as? String, !title.isEmpty else { return nil }
                    return Decision(title: title, details: (item["details"] ?? item["description"] ?? "") as? String ?? "")
                }
            }
        }
        return []
    }

    private func parseActions(_ json: [String: Any]) -> [ActionItem] {
        for key in ["action_items", "actions", "Action Items", "next_steps", "Next Steps"] {
            if let items = json[key] as? [[String: Any]] {
                return items.compactMap { item in
                    guard let task = (item["task"] ?? item["action"] ?? item["title"] ?? item["item"]) as? String, !task.isEmpty else { return nil }
                    return ActionItem(task: task, owner: item["owner"] as? String, dueDate: nil)
                }
            }
        }
        return []
    }

    private func parseRisks(_ json: [String: Any]) -> [Risk] {
        for key in ["risks", "Risks", "risks_issues", "Risks & Issues"] {
            if let items = json[key] as? [[String: Any]] {
                return items.compactMap { item in
                    guard let risk = (item["risk"] ?? item["title"] ?? item["item"] ?? item["description"]) as? String, !risk.isEmpty else { return nil }
                    return Risk(risk: risk, details: (item["details"] as? String) ?? "", confidence: item["confidence"] as? Double)
                }
            }
        }
        return []
    }

    private func parseQuestions(_ json: [String: Any]) -> [OpenQuestion] {
        for key in ["open_questions", "questions", "Open Questions"] {
            if let items = json[key] as? [Any] {
                return items.compactMap { item in
                    if let str = item as? String, !str.isEmpty { return OpenQuestion(question: str) }
                    if let dict = item as? [String: Any], let q = (dict["question"] ?? dict["item"]) as? String, !q.isEmpty {
                        return OpenQuestion(question: q)
                    }
                    return nil
                }
            }
        }
        return []
    }

    // MARK: - Save

    func saveAnalysis(_ analysis: MeetingAnalysis, for itemID: UUID) throws {
        try fileStore.writeArtifact(analysis, fileName: "analysis.json", meetingId: itemID)
    }

    enum ServiceError: Error, LocalizedError {
        case templateNotFound(String)
        case invalidJSON
        case allAttemptsFailed

        var errorDescription: String? {
            switch self {
            case .templateNotFound(let id): "Template '\(id)' not found"
            case .invalidJSON: "LLM response is not valid JSON"
            case .allAttemptsFailed: "All analysis attempts failed"
            }
        }
    }
}
