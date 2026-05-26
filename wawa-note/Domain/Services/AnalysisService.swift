import Foundation
import OSLog

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
    let followUpEmailDraft: String?

    enum CodingKeys: String, CodingKey {
        case shortSummary = "short_summary"
        case detailedSummary = "detailed_summary"
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case risks
        case importantDates = "important_dates"
        case mentionedPeople = "mentioned_people"
        case mentionedSystems = "mentioned_systems"
        case followUpEmailDraft = "follow_up_email_draft"
    }

    struct DecisionItem: Decodable {
        let title: String
        let details: String?
        let sourceSegmentIds: [String]?
        let confidence: Double?
        enum CodingKeys: String, CodingKey {
            case title, details
            case sourceSegmentIds = "source_segment_ids"
            case confidence
        }
    }

    struct ActionItemDTO: Decodable {
        let task: String
        let owner: String?
        let dueDate: String?
        let sourceSegmentIds: [String]?
        let confidence: Double?
        enum CodingKeys: String, CodingKey {
            case task, owner
            case dueDate = "due_date"
            case sourceSegmentIds = "source_segment_ids"
            case confidence
        }
    }

    struct QuestionItem: Decodable {
        let question: String
        let sourceSegmentIds: [String]?
        let confidence: Double?
        enum CodingKeys: String, CodingKey {
            case question
            case sourceSegmentIds = "source_segment_ids"
            case confidence
        }
    }

    struct RiskItem: Decodable {
        let risk: String
        let details: String?
        let sourceSegmentIds: [String]?
        let confidence: Double?
        enum CodingKeys: String, CodingKey {
            case risk, details
            case sourceSegmentIds = "source_segment_ids"
            case confidence
        }
    }

    struct DateItem: Decodable {
        let date: String
        let meaning: String?
        let sourceSegmentIds: [String]?
        enum CodingKeys: String, CodingKey {
            case date, meaning
            case sourceSegmentIds = "source_segment_ids"
        }
    }
}

// MARK: - Service

final class AnalysisService: Sendable {
    private let promptTemplate: String

    init() {
        self.promptTemplate = """
        You are analyzing a meeting transcript.

        Return structured JSON with these fields (use null for empty arrays):
        - short_summary: string
        - detailed_summary: string
        - decisions: array of {title, details, source_segment_ids, confidence}
        - action_items: array of {task, owner, due_date, source_segment_ids, confidence}
        - open_questions: array of {question, source_segment_ids, confidence}
        - risks: array of {risk, details, source_segment_ids, confidence}
        - important_dates: array of {date, meaning, source_segment_ids}
        - mentioned_people: array of strings
        - mentioned_systems: array of strings
        - follow_up_email_draft: string

        Do not invent information. If something is unclear, mark it as uncertain.
        Every extracted item should include evidence from transcript segment IDs when available.
        Use the exact segment IDs shown in brackets.

        Meeting transcript:
        \(TRANSCRIPT_PLACEHOLDER)
        """
    }

    func analyze(transcript: Transcript, using provider: any AIProvider, model: String) async throws -> (analysis: MeetingAnalysis, rawContent: String?) {
        let segmentsText = transcript.segments.map { segment in
            "[\(segment.id.uuidString)|\(formatTime(segment.startTime))] \(segment.text)"
        }.joined(separator: "\n")

        let prompt = promptTemplate.replacingOccurrences(of: "\(TRANSCRIPT_PLACEHOLDER)", with: segmentsText)

        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text("You are a meeting analysis assistant. Return only valid JSON.")]),
                AIMessage(role: .user, content: [.text(prompt)])
            ],
            temperature: 0.3,
            responseFormat: .json
        )

        let response = try await provider.send(request)
        let meetingId = transcript.meetingId ?? UUID()

        guard let data = response.content.data(using: .utf8) else {
            throw ProviderError.decodingFailed
        }

        let decoder = JSONDecoder()
        do {
            let parsed = try decoder.decode(AnalysisResponse.self, from: data)
            return (buildAnalysis(from: parsed, meetingId: meetingId, providerId: provider.id, model: model), nil)
        } catch {
            AppLog.provider.error("Failed to parse analysis JSON: \(error.localizedDescription)")
            return (buildFallback(rawContent: response.content, meetingId: meetingId, providerId: provider.id, model: model), response.content)
        }
    }

    // MARK: - Private

    private func parseSegmentIds(_ strings: [String]?) -> [UUID] {
        strings?.compactMap(UUID.init(uuidString:)) ?? []
    }

    private func buildAnalysis(from parsed: AnalysisResponse, meetingId: UUID, providerId: String, model: String) -> MeetingAnalysis {
        MeetingAnalysis(
            meetingId: meetingId,
            providerId: providerId,
            model: model,
            shortSummary: parsed.shortSummary ?? "",
            detailedSummary: parsed.detailedSummary ?? "",
            decisions: parsed.decisions?.map {
                Decision(title: $0.title, details: $0.details ?? "", sourceSegmentIds: parseSegmentIds($0.sourceSegmentIds), confidence: $0.confidence)
            } ?? [],
            actionItems: parsed.actionItems?.map {
                ActionItem(task: $0.task, owner: $0.owner, dueDate: parseDate($0.dueDate), sourceSegmentIds: parseSegmentIds($0.sourceSegmentIds), confidence: $0.confidence)
            } ?? [],
            risks: parsed.risks?.map {
                Risk(risk: $0.risk, details: $0.details ?? "", sourceSegmentIds: parseSegmentIds($0.sourceSegmentIds), confidence: $0.confidence)
            } ?? [],
            openQuestions: parsed.openQuestions?.map {
                OpenQuestion(question: $0.question, sourceSegmentIds: parseSegmentIds($0.sourceSegmentIds), confidence: $0.confidence)
            } ?? [],
            importantDates: parsed.importantDates?.map {
                ImportantDate(date: $0.date, meaning: $0.meaning ?? "", sourceSegmentIds: parseSegmentIds($0.sourceSegmentIds))
            } ?? [],
            entities: buildEntities(people: parsed.mentionedPeople, systems: parsed.mentionedSystems),
            topicTimeline: []
        )
    }

    private func buildEntities(people: [String]?, systems: [String]?) -> [EntityMention] {
        var entities: [EntityMention] = []
        people?.forEach { entities.append(EntityMention(name: $0, type: .person)) }
        systems?.forEach { entities.append(EntityMention(name: $0, type: .system)) }
        return entities
    }

    private func buildFallback(rawContent: String, meetingId: UUID, providerId: String, model: String) -> MeetingAnalysis {
        MeetingAnalysis(
            meetingId: meetingId,
            providerId: providerId,
            model: model,
            shortSummary: "Analysis could not be parsed.",
            detailedSummary: "See provider.response.raw.txt for the full response.",
            rawProviderResponsePath: "provider.response.raw.txt"
        )
    }

    func saveRawResponse(_ content: String, meetingId: UUID, fileStore: FileArtifactStore = FileArtifactStore()) {
        guard let data = content.data(using: .utf8) else { return }
        let url = fileStore.meetingDirectoryURL(for: meetingId).appendingPathComponent("provider.response.raw.txt")
        try? data.write(to: url, options: .atomic)
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private let TRANSCRIPT_PLACEHOLDER = "TRANSCRIPT_PLACEHOLDER"
