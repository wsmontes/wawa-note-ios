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
            if request.results == nil {
                continuation.resume(returning: nil)
            }
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
        return nil
    }

    // MARK: - Analyze text (source-aware)

    /// Runs AI analysis on extracted text. The system prompt and user prompt structure
    /// adapt to the item's source type so the LLM understands context: a recording gets
    /// meeting-analysis framing, a scan gets document-structure framing, etc.
    func analyze(text: String, item: KnowledgeItem) async -> Bool {
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            AppLog.provider.warning("ContentExtraction.analyze: no provider configured")
            return false
        }

        let settings = AutomationSettings.shared
        let model = settings.resolveAutoAnalysisModel(context: modelContext) ?? settings.autoAnalysisModel

        let sourceCtx = SourceContext.from(item)

        // Build synthetic transcript from text chunks for AnalysisService
        let segments = chunkText(text, itemID: item.id)
        let sourceId = segments.count > 1 ? "text-chunked" : "text-direct"
        let transcript = Transcript(meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: sourceId)

        AppLog.provider.info("ContentExtraction.analyze: source=\(sourceCtx.sourceType.rawValue), \(segments.count) segments, model \(model)")

        do {
            let result = try await AnalysisService().analyze(
                transcript: transcript,
                using: provider,
                model: model,
                meetingId: item.id,
                sourceContext: sourceCtx
            )

            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)

            item.status = .analyzed
            item.analysisProviderId = model
            try modelContext.save()

            AppLog.provider.info("ContentExtraction.analyze: done — \(result.shortSummary.prefix(80))")
            NotificationCenter.default.post(name: .analysisReady, object: item.id.uuidString)

            await EmbeddingPipelineService().ensureEmbedding(for: item, using: provider)

            return true
        } catch {
            AppLog.provider.error("ContentExtraction.analyze: failed for item \(item.id): \(error)")
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
        } else if item.isImported, let source = item.importSourceURL {
            sourceType = .import_
            metadata["filename"] = URL(string: source)?.lastPathComponent ?? source
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
