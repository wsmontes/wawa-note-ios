import Foundation
import OSLog

// MARK: - Response DTOs

private struct AnalysisResponse: Decodable {
    let shortSummary: String?
    let detailedSummary: String?
    let decisions: [DecisionItem]?
    let actionItems: [ActionItemDTO]?
    let openQuestions: [QuestionItem]?
    let risks: [RiskItem]?
    let importantDates: [DateItem]?
    let mentionedPeople: [String]?
    let mentionedSystems: [String]?
    let mentionedOrganizations: [String]?
    let mentionedRepositories: [String]?
    let mentionedLocations: [String]?
    let followUpEmailDraft: String?

    enum CodingKeys: String, CodingKey {
        case shortSummary = "short_summary", detailedSummary = "detailed_summary"
        case decisions, actionItems = "action_items", openQuestions = "open_questions"
        case risks, importantDates = "important_dates", mentionedPeople = "mentioned_people"
        case mentionedSystems = "mentioned_systems", mentionedOrganizations = "mentioned_organizations"
        case mentionedRepositories = "mentioned_repositories", mentionedLocations = "mentioned_locations"
        case followUpEmailDraft = "follow_up_email_draft"
    }

    struct DecisionItem: Decodable {
        let title: String; let details: String?
        let sourceSegmentIds: [String]?; let confidence: Double?
        enum CodingKeys: String, CodingKey { case title, details, sourceSegmentIds = "source_segment_ids", confidence }
    }
    struct ActionItemDTO: Decodable {
        let task: String; let owner: String?; let dueDate: String?
        let sourceSegmentIds: [String]?; let confidence: Double?
        enum CodingKeys: String, CodingKey { case task, owner, dueDate = "due_date", sourceSegmentIds = "source_segment_ids", confidence }
    }
    struct QuestionItem: Decodable {
        let question: String; let sourceSegmentIds: [String]?; let confidence: Double?
        enum CodingKeys: String, CodingKey { case question, sourceSegmentIds = "source_segment_ids", confidence }
    }
    struct RiskItem: Decodable {
        let risk: String; let details: String?
        let sourceSegmentIds: [String]?; let confidence: Double?
        enum CodingKeys: String, CodingKey { case risk, details, sourceSegmentIds = "source_segment_ids", confidence }
    }
    struct DateItem: Decodable {
        let date: String; let meaning: String?; let sourceSegmentIds: [String]?
        enum CodingKeys: String, CodingKey { case date, meaning, sourceSegmentIds = "source_segment_ids" }
    }
}

// MARK: - Progress

enum AnalysisProgress: Sendable {
    case mapping(Int, Int)    // current chunk, total chunks
    case reducing
    case done
}

// MARK: - Service

final class AnalysisService: @unchecked Sendable {
    private let configService = AIConfigService.shared
    private let chunker = TranscriptChunker()

    nonisolated(unsafe) var onProgress: (@Sendable (AnalysisProgress) -> Void)?

    func analyze(transcript: Transcript, using provider: any AIProvider, model: String) async throws -> MeetingAnalysis {
        let cfg = configService.featureConfig(for: "analysis")
        let systemPrompt = cfg?.systemPrompt ?? "You are a meeting analysis assistant. Return only valid JSON."
        let segmentsText = transcript.segments.map { seg in
            "[\(seg.id.uuidString)|\(formatTime(seg.startTime))] \(seg.text)"
        }

        // Check if chunking is needed
        let totalChars = segmentsText.reduce(0) { $0 + $1.count }
        if totalChars <= chunker.maxCharsPerChunk {
            // Direct path — transcript fits in one request
            let userPrompt = configService.renderPrompt(for: "analysis", variables: ["transcript": segmentsText.joined(separator: "\n")])
            return try await singleAnalysis(provider: provider, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        }

        // Map-Reduce path
        AppLog.provider.info("Transcript is \(totalChars) chars, using map-reduce")
        let chunks = chunker.chunkTranscript(transcript)
        return try await mapReduceAnalysis(chunks: chunks, provider: provider, model: model, systemPrompt: systemPrompt)
    }

    // MARK: - Direct (single request)

    private func singleAnalysis(provider: any AIProvider, model: String, systemPrompt: String, userPrompt: String) async throws -> MeetingAnalysis {
        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(userPrompt)])
            ]
        )
        let response = try await provider.send(request)
        return parseResponse(response.content, meetingId: UUID(), providerId: provider.id, model: model)
    }

    // MARK: - Map-Reduce

    private func mapReduceAnalysis(chunks: [TextChunk], provider: any AIProvider, model: String, systemPrompt: String) async throws -> MeetingAnalysis {
        // MAP: Summarize each chunk in parallel
        let chunkSummaries: [String] = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, chunk) in chunks.enumerated() {
                group.addTask {
                    let summary = try await self.summarizeChunk(chunk, index: i, total: chunks.count, provider: provider, model: model)
                    return (i, summary)
                }
            }
            var results: [(Int, String)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        AppLog.provider.info("Map phase done: \(chunkSummaries.count) summaries")

        // REDUCE: Consolidate summaries into final analysis
        await MainActor.run { onProgress?(.reducing) }

        let combined = chunkSummaries.enumerated().map { idx, summary in
            "--- Part \(idx + 1) of \(chunkSummaries.count) ---\n\(summary)"
        }.joined(separator: "\n\n")

        let reducePrompt = """
        Below are summaries from different parts of a long meeting. Synthesize them into a complete meeting analysis.
        Extract: short_summary, detailed_summary, decisions (title, details), action_items (task, owner, due_date), open_questions, risks (risk, details), important_dates (date, meaning), mentioned_people, mentioned_systems, mentioned_organizations, mentioned_repositories, mentioned_locations.

        \(combined)

        Return only valid JSON with these keys: short_summary, detailed_summary, decisions, action_items, open_questions, risks, important_dates, mentioned_people, mentioned_systems, mentioned_organizations, mentioned_repositories, mentioned_locations.
        """

        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(reducePrompt)])
            ]
        )
        let response = try await provider.send(request)
        return parseResponse(response.content, meetingId: UUID(), providerId: provider.id, model: model)
    }

    private func summarizeChunk(_ chunk: TextChunk, index: Int, total: Int, provider: any AIProvider, model: String) async throws -> String {
        await MainActor.run { onProgress?(.mapping(index + 1, total)) }

        let prompt = """
        You are a meeting note taker. Summarize this meeting excerpt concisely.
        Focus on: key decisions, action items, risks, open questions, important dates, people mentioned, systems mentioned.

        Meeting excerpt (part \(index + 1) of \(total)):
        \(chunk.text)
        """

        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text("You are a concise meeting summarizer. Return only the summary text, no JSON.")]),
                AIMessage(role: .user, content: [.text(prompt)])
            ]
        )
        let response = try await provider.send(request)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parse

    private func parseResponse(_ content: String, meetingId: UUID, providerId: String, model: String) -> MeetingAnalysis {
        guard let data = content.data(using: .utf8) else {
            return buildFallback(rawContent: content, meetingId: meetingId, providerId: providerId, model: model)
        }

        do {
            let parsed = try JSONDecoder().decode(AnalysisResponse.self, from: data)
            return buildAnalysis(from: parsed, meetingId: meetingId, providerId: providerId, model: model)
        } catch {
            AppLog.provider.error("Failed to parse analysis JSON: \(error.localizedDescription)")
            return buildFallback(rawContent: content, meetingId: meetingId, providerId: providerId, model: model)
        }
    }

    private func buildAnalysis(from parsed: AnalysisResponse, meetingId: UUID, providerId: String, model: String) -> MeetingAnalysis {
        MeetingAnalysis(
            meetingId: meetingId, providerId: providerId, model: model,
            shortSummary: parsed.shortSummary ?? "",
            detailedSummary: parsed.detailedSummary ?? "",
            decisions: parsed.decisions?.map { Decision(title: $0.title, details: $0.details ?? "", sourceSegmentIds: parseIDs($0.sourceSegmentIds), confidence: $0.confidence) } ?? [],
            actionItems: parsed.actionItems?.map { ActionItem(task: $0.task, owner: $0.owner, dueDate: parseDate($0.dueDate), sourceSegmentIds: parseIDs($0.sourceSegmentIds), confidence: $0.confidence) } ?? [],
            risks: parsed.risks?.map { Risk(risk: $0.risk, details: $0.details ?? "", sourceSegmentIds: parseIDs($0.sourceSegmentIds), confidence: $0.confidence) } ?? [],
            openQuestions: parsed.openQuestions?.map { OpenQuestion(question: $0.question, sourceSegmentIds: parseIDs($0.sourceSegmentIds), confidence: $0.confidence) } ?? [],
            importantDates: parsed.importantDates?.map { ImportantDate(date: $0.date, meaning: $0.meaning ?? "", sourceSegmentIds: parseIDs($0.sourceSegmentIds)) } ?? [],
            entities: buildEntities(
                people: parsed.mentionedPeople, systems: parsed.mentionedSystems,
                organizations: parsed.mentionedOrganizations, repositories: parsed.mentionedRepositories,
                locations: parsed.mentionedLocations
            ),
            topicTimeline: []
        )
    }

    private func buildFallback(rawContent: String, meetingId: UUID, providerId: String, model: String) -> MeetingAnalysis {
        MeetingAnalysis(
            meetingId: meetingId, providerId: providerId, model: model,
            shortSummary: "Analysis could not be parsed.",
            detailedSummary: "See raw response for details.",
            rawProviderResponsePath: "provider.response.raw.txt"
        )
    }

    func saveRawResponse(_ content: String, meetingId: UUID, fileStore: FileArtifactStore = FileArtifactStore()) {
        let url = fileStore.meetingDirectoryURL(for: meetingId).appendingPathComponent("provider.response.raw.txt")
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func parseIDs(_ strings: [String]?) -> [UUID] {
        strings?.compactMap(UUID.init(uuidString:)) ?? []
    }
    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f.date(from: s)
    }
    private func buildEntities(
        people: [String]?, systems: [String]?,
        organizations: [String]?, repositories: [String]?,
        locations: [String]?
    ) -> [EntityMention] {
        var e: [EntityMention] = []
        people?.forEach { e.append(EntityMention(name: $0, type: .person)) }
        systems?.forEach { e.append(EntityMention(name: $0, type: .system)) }
        organizations?.forEach { e.append(EntityMention(name: $0, type: .organization)) }
        repositories?.forEach { e.append(EntityMention(name: $0, type: .repository)) }
        locations?.forEach { e.append(EntityMention(name: $0, type: .location)) }
        return e
    }
    private func formatTime(_ s: Double) -> String {
        let m = Int(s)/60, sec = Int(s)%60; return String(format: "%02d:%02d", m, sec)
    }
}
