import Foundation
import SwiftData
import UIKit
import Vision

// MARK: - Text extraction from any content type

/// Extracts text from content items. The single source of text for analysis,
/// regardless of the original medium.
///
/// - Audio  → transcribes to transcript.json, returns concatenated segment text
/// - Text   → returns item.bodyText directly
/// - Image  → (future) LLM description extraction
@MainActor
final class ContentExtractionService {
    private let modelContext: ModelContext
    private let fileStore: FileArtifactStore

    init(modelContext: ModelContext, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.modelContext = modelContext
        self.fileStore = fileStore
    }

    // MARK: - Audio → text

    /// Returns existing transcript text if available, otherwise transcribes and returns text.
    /// Never returns nil as long as a transcript exists on disk — extraction failure
    /// falls back to the existing transcript instead of blocking Phase 3.
    func extractTextFromAudio(_ item: KnowledgeItem) async -> String? {
        // Reuse existing transcript when available — avoids re-transcribing
        // and prevents a failed re-transcription from blocking project ingestion.
        if let existing = loadExistingTranscriptText(for: item.id) {
            AppLog.provider.info("ContentExtraction: reusing existing transcript for item \(item.id)")
            return existing
        }

        let audioURL = fileStore.audioFileURL(for: item.id)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            AppLog.provider.warning("ContentExtraction: no audio file for item \(item.id)")
            return nil
        }

        let engine: TranscriptionEngine
        let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext)
        if let config, config.type == .openAI || config.type == .openAICompatible,
           let baseURL = config.baseURL {
            var apiKey = ""
            if let keyId = config.apiKeyKeychainIdentifier {
                apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
            }
            engine = RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
        } else {
            engine = AppleSpeechTranscriptionEngine()
        }

        do {
            var result = try await engine.transcribeFile(audioURL)
            result.meetingId = item.id
            result.segments = result.segments.map { var f = $0; f.meetingId = item.id; return f }

            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: item.id)

            item.status = .transcribed
            item.transcriptionEngineId = engine.id
            try modelContext.save()

            NotificationCenter.default.post(name: .transcriptReady, object: item.id.uuidString)

            AppLog.provider.info("ContentExtraction: transcription complete (\(result.segments.count) segments)")
            return result.segments.map(\.text).joined(separator: "\n")
        } catch {
            AppLog.provider.error("ContentExtraction: transcription failed for item \(item.id): \(error)")
            // Fall back to existing transcript if available (may have been saved by a prior run)
            if let fallback = loadExistingTranscriptText(for: item.id) {
                AppLog.provider.warning("ContentExtraction: falling back to existing transcript for item \(item.id)")
                return fallback
            }
            return nil
        }
    }

    /// Reads transcript text from an already-saved transcript.json, if it exists.
    private func loadExistingTranscriptText(for itemID: UUID) -> String? {
        guard let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: itemID),
              !transcript.segments.isEmpty else { return nil }
        return transcript.segments.map(\.text).joined(separator: "\n")
    }

    // MARK: - Document → text

    func extractTextFromDocument(_ item: KnowledgeItem) async -> String? {
        guard let bodyText = item.bodyText, !bodyText.isEmpty else {
            AppLog.provider.warning("ContentExtraction: no bodyText for item \(item.id)")
            return nil
        }
        AppLog.provider.info("ContentExtraction: using bodyText (\(bodyText.count) chars)")
        return bodyText
    }

    // MARK: - Image → text

    func extractTextFromImage(_ item: KnowledgeItem) async -> String? {
        if let body = item.bodyText, !body.isEmpty {
            return body
        }
        guard let relativePath = item.imageFileRelativePath else { return nil }
        let imageURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent(relativePath)
        guard let imageData = try? Data(contentsOf: imageURL),
              let image = UIImage(data: imageData),
              let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    // MARK: - Best-effort text retrieval

    /// Returns the best available text for an item without running expensive extraction.
    /// Checks transcript (audio) or bodyText (documents). Falls back to analysis summary.
    /// Used when the pipeline needs text for Phase 3 but extraction isn't required.
    func bestAvailableText(for item: KnowledgeItem) -> String? {
        if let transcript = loadExistingTranscriptText(for: item.id) {
            return transcript
        }
        if let body = item.bodyText, !body.isEmpty {
            return body
        }
        if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            let parts = [analysis.shortSummary, analysis.detailedSummary].filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        if let dynamic = try? fileStore.readArtifact(DynamicAnalysis.self, fileName: "analysis.dynamic.json", meetingId: item.id),
           let summary = dynamic.results.stringField("short_summary") {
            return summary
        }
        return nil
    }

    // MARK: - Analyze text (source-aware)

    /// Runs AI analysis on extracted text. Uses an iterative agent pattern:
    /// the model can call tools (search, get_item, get_project) to gather context
    /// before producing the final analysis. The model decides when it has enough.
    func analyze(text: String, item: KnowledgeItem) async -> Bool {
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            AppLog.provider.warning("ContentExtraction.analyze: no provider configured")
            return false
        }

        let settings = AutomationSettings.shared
        let model = ModelTierResolver.resolveForAnalysis(item: item)
        let sourceCtx = SourceContext.from(item)

        let segments = chunkText(text, itemID: item.id)
        let transcript = Transcript(meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: "text-direct")

        AppLog.provider.info("ContentExtraction.analyze: source=\(sourceCtx.sourceType.rawValue), model=\(model), iterative")

        do {
            // Build the iterative prompt — model has tools to explore context
            let systemPrompt = sourceCtx.analysisSystemPrompt()
            let prefix = sourceCtx.userPromptPrefix()
            let body = segments.map { $0.text }.joined(separator: "\n")
            let userPrompt = """
            \(prefix)Analyze the following content. You may call tools (search_knowledge, get_item, get_project) to gather additional context before producing your analysis. When you have enough information, return the final analysis JSON. Do not guess — if you're uncertain about something, search for related items to confirm.

            CONTENT TO ANALYZE:
            \(body.prefix(12000))

            Return a complete analysis JSON with short_summary, detailed_summary, decisions, action_items, risks, open_questions, important_dates, mentioned_people, mentioned_systems, mentioned_organizations, mentioned_locations.
            """

            // Use iterative agent loop with analysis tools
            let toolContext = ToolContext(modelContext: modelContext)
            let analysisTools: [any AgentTool] = [
                SearchKnowledgeTool(), GetItemTool(), GetProjectTool()
            ]
            let registry = AgentToolRegistry(tools: analysisTools)
            let loop = AgentLoop(registry: registry, toolContext: toolContext, maxIterations: 4, mode: .auto, executorModel: model, advisorModel: ModelTierResolver.advisorModel)

            var fullResponse = ""
            let stream = loop.runStreaming(userMessage: userPrompt, history: [], provider: provider)
            for try await event in stream {
                if case .textDelta(let d) = event { fullResponse += d }
            }

            // The iterative agent produces the analysis as its final text output.
            // Save raw text and run structured parse for the artifact.
            try fileStore.createMeetingDirectory(for: item.id)
            let rawURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("analysis.iterative.txt")
            try fullResponse.data(using: .utf8)?.write(to: rawURL)
            AppLog.provider.info("ContentExtraction.analyze: iterative complete (\(fullResponse.count) chars)")

            // Parse through AnalysisService for structured output
            let segments2 = chunkText(fullResponse, itemID: item.id)
            let iterTranscript = Transcript(meetingId: item.id, languageCode: nil, segments: segments2, sourceEngineId: "iterative-analysis")
            return await analyzeStructured(transcript: iterTranscript, item: item, sourceCtx: sourceCtx, provider: provider, model: model)
        } catch {
            AppLog.provider.error("ContentExtraction.analyze: failed for item \(item.id): \(error)")
            return false
        }
    }

    /// Parses agent output into structured MeetingAnalysis artifact.
    private func analyzeStructured(transcript: Transcript, item: KnowledgeItem, sourceCtx: SourceContext, provider: any AIProvider, model: String) async -> Bool {
        do {
            let result = try await AnalysisService().analyze(transcript: transcript, using: provider, model: model, meetingId: item.id, sourceContext: sourceCtx)
            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)
            item.status = .analyzed
            item.analysisProviderId = model
            try modelContext.save()
            AppLog.provider.info("ContentExtraction.analyze: done — \(result.shortSummary.prefix(80))")
            NotificationCenter.default.post(name: .analysisReady, object: item.id.uuidString)
            await EmbeddingPipelineService().ensureEmbedding(for: item, using: provider)
            return true
        } catch { return false }
    }

    /// Framework-driven analysis: uses the project's framework to determine
    /// the output schema and system prompt. Returns DynamicAnalysis.
    func analyzeDynamic(text: String, item: KnowledgeItem, framework: ProjectFramework) async -> Bool {
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            AppLog.provider.warning("ContentExtraction.analyzeDynamic: no provider configured")
            return false
        }

        let model = ModelTierResolver.resolveForAnalysis(item: item)
        let sourceCtx = SourceContext.from(item)
        let segments = chunkText(text, itemID: item.id)
        let transcript = Transcript(meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: "text-direct")

        AppLog.provider.info("ContentExtraction.analyzeDynamic: framework=\(framework.id), source=\(sourceCtx.sourceType.rawValue), model=\(model)")

        do {
            let result = try await AnalysisService().analyzeDynamic(
                transcript: transcript, using: provider, model: model,
                meetingId: item.id, sourceContext: sourceCtx,
                schema: framework.itemAnalysis.outputSchema,
                systemPrompt: framework.itemAnalysis.systemPrompt
            )

            try fileStore.createMeetingDirectory(for: item.id)
            let resultData = try JSONEncoder().encode(result)
            try resultData.write(to: fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("analysis.dynamic.json"))

            item.status = .analyzed
            item.analysisProviderId = model
            try modelContext.save()

            AppLog.provider.info("ContentExtraction.analyzeDynamic: done for item \(item.id)")
            NotificationCenter.default.post(name: .analysisReady, object: item.id.uuidString)

            await EmbeddingPipelineService().ensureEmbedding(for: item, using: provider)
            return true
        } catch {
            AppLog.provider.error("ContentExtraction.analyzeDynamic: failed for item \(item.id): \(error)")
            return false
        }
    }

    // MARK: - Text chunking

    private static let maxChunkChars = 8000

    private func chunkText(_ text: String, itemID: UUID) -> [TranscriptSegment] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var segments: [TranscriptSegment] = []
        var currentChunk = ""
        var segmentIndex = 0

        for para in paragraphs where !para.trimmingCharacters(in: .whitespaces).isEmpty {
            if currentChunk.isEmpty {
                currentChunk = para
            } else if (currentChunk + "\n\n" + para).count <= Self.maxChunkChars {
                currentChunk += "\n\n" + para
            } else {
                segments.append(TranscriptSegment(
                    meetingId: itemID, startTime: Double(segmentIndex),
                    text: currentChunk, sourceEngineId: "text-chunk"
                ))
                segmentIndex += 1
                currentChunk = para

                if para.count > Self.maxChunkChars {
                    let subChunks = splitLongParagraph(para, itemID: itemID, startIdx: segmentIndex)
                    segments.append(contentsOf: subChunks)
                    segmentIndex += subChunks.count
                    currentChunk = ""
                }
            }
        }

        if !currentChunk.isEmpty {
            segments.append(TranscriptSegment(
                meetingId: itemID, startTime: Double(segmentIndex),
                text: currentChunk, sourceEngineId: "text-chunk"
            ))
        }

        if segments.isEmpty {
            segments.append(TranscriptSegment(
                meetingId: itemID, startTime: 0, text: text, sourceEngineId: "text-direct"
            ))
        }

        return segments
    }

    private func splitLongParagraph(_ text: String, itemID: UUID, startIdx: Int) -> [TranscriptSegment] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var segments: [TranscriptSegment] = []
        var current = ""
        var idx = startIdx

        for sentence in sentences {
            let candidate = current.isEmpty ? sentence : current + ". " + sentence
            if candidate.count <= Self.maxChunkChars {
                current = candidate
            } else {
                if !current.isEmpty {
                    segments.append(TranscriptSegment(meetingId: itemID, startTime: Double(idx), text: current, sourceEngineId: "text-chunk"))
                    idx += 1
                }
                current = sentence
            }
        }
        if !current.isEmpty {
            segments.append(TranscriptSegment(meetingId: itemID, startTime: Double(idx), text: current, sourceEngineId: "text-chunk"))
        }
        return segments
    }
}

// MARK: - Source Context

/// Describes where an item came from so the analysis prompt can adapt.
/// A meeting transcript, an imported PDF, a scanned document, and a manual note
/// all need different AI framing to produce useful structured output.
struct SourceContext: Sendable {
    enum SourceType: String, Sendable {
        case recording
        case import_
        case scan
        case note
    }

    let sourceType: SourceType
    let metadata: [String: String]

    static func from(_ item: KnowledgeItem) -> SourceContext {
        let sourceType: SourceType
        var metadata: [String: String] = [:]

        if item.audioFileRelativePath != nil {
            sourceType = .recording
            if let dur = item.durationSeconds { metadata["duration"] = formatDuration(dur) }
            if let lang = item.languageCode { metadata["language"] = lang }
        } else if item.imageFileRelativePath != nil {
            sourceType = .scan
            if let pages = item.imagePageCount { metadata["pageCount"] = String(pages) }
        } else if item.isImported {
            sourceType = .import_
            if let source = item.importSourceURL {
                metadata["filename"] = URL(string: source)?.lastPathComponent ?? source
            }
        } else {
            sourceType = .note
        }

        metadata["createdAt"] = item.createdAt.formatted(date: .complete, time: .shortened)
        if !item.tags.isEmpty { metadata["tags"] = item.tags.joined(separator: ", ") }

        return SourceContext(sourceType: sourceType, metadata: metadata)
    }

    /// Builds the analysis system prompt for this source type.
    /// Each source gets a different analytical lens — a meeting transcript needs
    /// decisions/actions/risks extraction, while a scanned document needs
    /// structure analysis and clause identification.
    func analysisSystemPrompt() -> String {
        switch sourceType {
        case .recording:
            return "You are a meeting intelligence analyst. Extract decisions, action items with owners, risks, open questions, important dates, mentioned people/systems/organizations, and a topic timeline. Return only valid JSON."
        case .import_:
            return "You are a document analyst. Analyze this imported file. Identify its structure, key points, decisions if any, action items, risks, mentioned entities, and dates. Consider the filename and metadata for context. Return only valid JSON."
        case .scan:
            return "You are a document analyst. Analyze this scanned document (OCR text). Identify document structure, key clauses, dates, parties mentioned, obligations, risks, and action items if applicable. Note that OCR may have errors — flag uncertain readings. Return only valid JSON."
        case .note:
            return "You are a knowledge analyst. Analyze this note. Extract key themes, questions being explored, references to other topics, action items if any, and people/systems mentioned. Return only valid JSON."
        }
    }

    /// Builds a source-context prefix for the user prompt so the LLM knows
    /// what kind of content it's analyzing and any relevant metadata.
    func userPromptPrefix() -> String {
        var lines: [String] = []
        switch sourceType {
        case .recording:
            lines.append("The following is a meeting transcript.")
            if let dur = metadata["duration"] { lines.append("Duration: \(dur)") }
            if let lang = metadata["language"] { lines.append("Language: \(lang)") }
        case .import_:
            lines.append("The following is the content of an imported file.")
            if let fn = metadata["filename"] { lines.append("Filename: \(fn)") }
        case .scan:
            lines.append("The following is OCR-extracted text from a scanned document.")
            if let pages = metadata["pageCount"] { lines.append("Pages: \(pages)") }
        case .note:
            lines.append("The following is a user note.")
        }
        if let tags = metadata["tags"], !tags.isEmpty { lines.append("Tags: \(tags)") }
        if let createdAt = metadata["createdAt"] { lines.append("Created: \(createdAt)") }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}

// MARK: - Model Tier Resolver

/// Decides which model tier to use for analysis and ingestion based on content complexity,
/// project size, and framework type. Cheap models (nano/haiku) handle simple extraction
/// and small projects; expensive models (opus/gpt-5.5) handle complex analysis and large projects.
@MainActor
enum ModelTierResolver {
    /// Executor model — cheap, fast, good at extraction.
    static var executorModel: String {
        AIConfigService.shared.featureConfig(for: "agent")?.model
            ?? "gpt-5-nano"
    }

    /// Advisor model — expensive, smart, good at reasoning.
    /// Validated against active provider's available models, falls back to executor.
    static var advisorModel: String {
        let chatModel = AIConfigService.shared.featureConfig(for: "chat")?.model ?? "gpt-5.5"
        let analysisModel = AIConfigService.shared.featureConfig(for: "analysis")?.model
        return analysisModel ?? chatModel
    }

    /// Resolve which model to use for item analysis based on content complexity.
    static func resolveForAnalysis(item: KnowledgeItem) -> String {
        if item.durationSeconds.map({ $0 > 600 }) ?? false { return advisorModel }
        if item.imagePageCount.map({ $0 > 2 }) ?? false { return advisorModel }
        if let body = item.bodyText, body.count > 15000 { return advisorModel }
        return executorModel
    }

    /// Resolve which model to use for project ingestion based on project complexity.
    static func resolveForIngestion(projectID: UUID, context: ModelContext) -> String {
        let itemCount = (try? ProjectService(context: context).items(in: projectID).count) ?? 0
        if itemCount >= 3 { return advisorModel }
        return executorModel
    }
}
