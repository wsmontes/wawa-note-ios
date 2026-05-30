import Foundation
import SwiftData

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

    func extractTextFromAudio(_ item: KnowledgeItem) async -> String? {
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
            return nil
        }
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

    // MARK: - Analyze text (always the same, regardless of source)

    /// Runs AI analysis on extracted text. The text source doesn't matter —
    /// this is always the same analysis pipeline.
    func analyze(text: String, item: KnowledgeItem) async -> Bool {
        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            AppLog.provider.warning("ContentExtraction.analyze: no provider configured")
            return false
        }

        let settings = AutomationSettings.shared
        let model = settings.resolveAutoAnalysisModel(context: modelContext) ?? settings.autoAnalysisModel

        // Build synthetic transcript from text chunks for AnalysisService
        let segments = chunkText(text, itemID: item.id)
        let sourceId = segments.count > 1 ? "text-chunked" : "text-direct"
        let transcript = Transcript(meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: sourceId)

        AppLog.provider.info("ContentExtraction.analyze: \(segments.count) segments, model \(model)")

        do {
            let result = try await AnalysisService().analyze(transcript: transcript, using: provider, model: model, meetingId: item.id)

            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)

            item.status = .analyzed
            item.analysisProviderId = model
            try modelContext.save()

            AppLog.provider.info("ContentExtraction.analyze: done — \(result.shortSummary.prefix(80))")
            NotificationCenter.default.post(name: .analysisReady, object: item.id.uuidString)

            // Generate embedding for semantic search
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
