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
    case mapping(Int, Int)
    case reducing
    case done
}

// MARK: - Service

final class AnalysisService: @unchecked Sendable {
    private let configService = AIConfigService.shared
    private let chunker = TranscriptChunker()
    private let fileStore = FileArtifactStore()

    nonisolated(unsafe) var onProgress: (@Sendable (AnalysisProgress) -> Void)?

    func analyze(transcript: Transcript, using provider: any AIProvider, model: String, meetingId: UUID = UUID()) async throws -> MeetingAnalysis {
        let cfg = configService.featureConfig(for: "analysis")
        let systemPrompt = cfg?.systemPrompt ?? "You are a meeting analysis assistant. Return only valid JSON."
        let segmentsText = transcript.segments.map { seg in
            "[\(seg.id.uuidString)|\(formatTime(seg.startTime))] \(seg.text)"
        }

        let totalChars = segmentsText.reduce(0) { $0 + $1.count }
        let maxChunk = configService.maxChunkChars(for: model)
        AppLog.provider.info("Transcript: \(totalChars) chars, model \(model) chunk limit: \(maxChunk) chars")

        if totalChars <= maxChunk {
            let userPrompt = configService.renderPrompt(for: "analysis", variables: ["transcript": segmentsText.joined(separator: "\n")])
            return try await singleAnalysis(provider: provider, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt, meetingId: meetingId)
        }

        AppLog.provider.info("Using map-reduce for \(totalChars) chars (\(model) context)")
        let chunks = chunker.chunkTranscript(transcript, maxCharsPerChunk: maxChunk)
        return try await mapReduceAnalysis(chunks: chunks, provider: provider, model: model, systemPrompt: systemPrompt, meetingId: meetingId)
    }

    // MARK: - Direct (single request)

    private func singleAnalysis(provider: any AIProvider, model: String, systemPrompt: String, userPrompt: String, meetingId: UUID) async throws -> MeetingAnalysis {
        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text(systemPrompt)]),
                AIMessage(role: .user, content: [.text(userPrompt)])
            ],
            responseFormat: .jsonObject
        )
        let response = try await provider.send(request)
        return await parseResponse(response.content, meetingId: meetingId, providerId: provider.id, model: model, provider: provider)
    }

    // MARK: - Map-Reduce

    private static let maxConcurrentChunks = 3
    private static let maxRetries = 3

    private func mapReduceAnalysis(chunks: [TextChunk], provider: any AIProvider, model: String, systemPrompt: String, meetingId: UUID) async throws -> MeetingAnalysis {
        let chunkSummaries = await summarizeChunksWithLimit(chunks, provider: provider, model: model)

        let validSummaries = chunkSummaries.compactMap(\.value)
        let failedCount = chunkSummaries.count - validSummaries.count
        if failedCount > 0 {
            AppLog.provider.warning("Map phase: \(failedCount)/\(chunkSummaries.count) chunks failed after retries")
        }

        guard !validSummaries.isEmpty else {
            throw ProviderError.decodingFailed
        }

        AppLog.provider.info("Map phase done: \(validSummaries.count) summaries")

        await MainActor.run { onProgress?(.reducing) }

        let combined = validSummaries.enumerated().map { idx, summary in
            "--- Part \(idx + 1) of \(validSummaries.count) ---\n\(summary)"
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
            ],
            responseFormat: .jsonObject
        )
        let response = try await sendWithRetry(provider: provider, request: request, maxRetries: Self.maxRetries)
        return await parseResponse(response.content, meetingId: meetingId, providerId: provider.id, model: model, provider: provider)
    }

    private func summarizeChunksWithLimit(_ chunks: [TextChunk], provider: any AIProvider, model: String) async -> [(index: Int, value: String?)] {
        let total = chunks.count
        var results: [(Int, String?)] = []
        results.reserveCapacity(total)

        var offset = 0
        while offset < total {
            let batchSize = min(Self.maxConcurrentChunks, total - offset)
            let batch = Array(chunks[offset..<(offset + batchSize)])

            let batchResults = await withTaskGroup(of: (Int, String?).self) { group in
                for i in 0..<batchSize {
                    let chunkIndex = offset + i
                    let chunk = batch[i]
                    group.addTask {
                        await MainActor.run { self.onProgress?(.mapping(chunkIndex + 1, total)) }
                        let summary = await self.summarizeChunkWithRetry(
                            chunk, index: chunkIndex, total: total,
                            provider: provider, model: model
                        )
                        return (chunkIndex, summary)
                    }
                }
                var collected: [(Int, String?)] = []
                for await r in group { collected.append(r) }
                return collected.sorted { $0.0 < $1.0 }
            }

            results.append(contentsOf: batchResults)
            offset += batchSize
        }

        return results
    }

    private func summarizeChunkWithRetry(_ chunk: TextChunk, index: Int, total: Int, provider: any AIProvider, model: String) async -> String? {
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

        do {
            let response = try await sendWithRetry(provider: provider, request: request, maxRetries: Self.maxRetries)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AppLog.provider.error("Chunk \(index + 1)/\(total) failed after retries: \(error)")
            return nil
        }
    }

    /// Retry a request with exponential backoff. Retries on server errors (500, 502, 503, 504),
    /// rate limits (429), timeouts, and transient network errors.
    private func sendWithRetry(provider: any AIProvider, request: AIRequest, maxRetries: Int) async throws -> AIResponse {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await provider.send(request)
            } catch let error as ProviderError {
                lastError = error
                let retryable: Bool = {
                    switch error {
                    case .apiError(let code, _):
                        return code >= 500 || code == 429
                    case .timeout, .networkUnavailable:
                        return true
                    default:
                        return false
                    }
                }()
                if retryable && attempt < maxRetries {
                    let delay = Double(1 << attempt) // 1s, 2s, 4s
                    AppLog.provider.warning("Retrying after \(delay)s (attempt \(attempt + 1)/\(maxRetries), \(error))")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            } catch {
                // Non-ProviderError — retry if transient
                lastError = error
                if attempt < maxRetries {
                    let delay = Double(1 << attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? ProviderError.requestFailed(statusCode: 0)
    }

    // MARK: - Parse

    private func parseResponse(_ content: String, meetingId: UUID, providerId: String, model: String, provider: any AIProvider) async -> MeetingAnalysis {
        // Attempt 1: direct parse
        let cleaned = ProviderAdapter.normalizeJSON(content)
        if let data = cleaned.data(using: .utf8),
           let parsed = tryDecode(AnalysisResponse.self, from: data) {
            return buildAnalysis(from: parsed, meetingId: meetingId, providerId: providerId, model: model)
        }

        // Attempt 2: retry with a "fix your JSON" prompt (save the failed response first)
        saveRawResponse(content, meetingId: meetingId)
        AppLog.provider.warning("Initial parse failed. Requesting JSON fix from provider...")

        if let parsed = await tryRetryWithFix(provider: provider, model: model, failedJSON: cleaned, meetingId: meetingId) {
            return buildAnalysis(from: parsed, meetingId: meetingId, providerId: providerId, model: model)
        }

        AppLog.provider.error("All parse attempts failed for meeting \(meetingId). Using fallback.")
        return buildFallback(rawContent: content, meetingId: meetingId, providerId: providerId, model: model)
    }

    /// Retry once with a "fix your JSON" prompt. Returns parsed DTO or nil.
    private func tryRetryWithFix(provider: any AIProvider, model: String, failedJSON: String, meetingId: UUID) async -> AnalysisResponse? {
        let fixPrompt = """
        Your previous response was not valid JSON. Here is what you returned:

        \(failedJSON.prefix(3000))

        Return ONLY valid JSON matching the original schema. No markdown, no code fences, no explanatory text. The JSON must parse correctly with a standard JSON parser.
        """

        let request = AIRequest(
            model: model,
            messages: [
                AIMessage(role: .system, content: [.text("You are a JSON repair assistant. Output ONLY valid JSON. No markdown, no code fences.")]),
                AIMessage(role: .user, content: [.text(fixPrompt)])
            ],
            responseFormat: .jsonObject
        )

        do {
            let response = try await provider.send(request)
            saveRawResponse(response.content, meetingId: meetingId, filename: "provider.response.fix_attempt.txt")
            let cleaned = ProviderAdapter.normalizeJSON(response.content)
            if let data = cleaned.data(using: .utf8),
               let parsed = tryDecode(AnalysisResponse.self, from: data) {
                AppLog.provider.info("JSON fix retry succeeded")
                return parsed
            }
        } catch {
            AppLog.provider.error("JSON fix retry failed: \(error)")
        }

        return nil
    }

    private func tryDecode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.provider.error("Decode failed for \(T.self): \(error)")
            return nil
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
        saveRawResponse(rawContent, meetingId: meetingId)
        return MeetingAnalysis(
            meetingId: meetingId, providerId: providerId, model: model,
            shortSummary: "Analysis could not be parsed.",
            detailedSummary: "See raw response for details.",
            rawProviderResponsePath: "provider.response.raw.txt"
        )
    }

    func saveRawResponse(_ content: String, meetingId: UUID, fileStore: FileArtifactStore = FileArtifactStore(), filename: String = "provider.response.raw.txt") {
        let url = fileStore.meetingDirectoryURL(for: meetingId).appendingPathComponent(filename)
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
