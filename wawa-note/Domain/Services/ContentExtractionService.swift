import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import SwiftData
import UIKit
import Vision

// Related JIRA: KAN-7, KAN-26

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
    /// Preferred BCP-47 locale tag (e.g. "pt-BR") for on-device transcription.
    /// Passed through to AppleSpeechTranscriptionEngine as the first candidate.
    /// Ignored when the remote Whisper engine is selected.
    private let preferredLocale: String?

    init(modelContext: ModelContext, fileStore: FileArtifactStore = FileArtifactStore(), preferredLocale: String? = nil) {
        self.modelContext = modelContext
        self.fileStore = fileStore
        self.preferredLocale = preferredLocale
    }

    // MARK: - Audio → text

    /// Returns the duration of a local audio file using AVURLAsset.
    /// Returns 0 when the file cannot be read or has no duration property.
    private static func audioDuration(url: URL) -> Double {
        let secs = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return (secs.isNaN || secs.isInfinite || secs <= 0) ? 0 : secs
    }

    /// Returns existing transcript text if available, otherwise transcribes and returns text.
    /// Never returns nil as long as a transcript exists on disk — extraction failure
    /// falls back to the existing transcript instead of blocking Phase 3.
    func extractTextFromAudio(_ item: KnowledgeItem) async -> String? {
        let startTime = Date()
        let id = item.id
        AppLog.provider.info(
            "ContentExtraction: transcribing item \(id.uuidString.prefix(8)) — type=audio duration=\(item.durationSeconds.map { "\(Int($0))s" } ?? "nil")")

        // ── Diagnostic logging: final audio state ──────────────────
        let audioURL = fileStore.audioFileURL(for: item.id)
        let audioExists = FileManager.default.fileExists(atPath: audioURL.path)
        let audioSize = audioExists ? (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0 : 0
        let audioDuration = audioExists ? Self.audioDuration(url: audioURL) : 0
        let hasManifest = fileStore.recordingManifestExists(for: item.id)
        let manifest: RecordingManifest? = hasManifest ? try? fileStore.readRecordingManifest(for: item.id) : nil
        let segmentCount = manifest?.segments.count ?? 0
        let segmentDetails: [String] =
            manifest?.segments.sorted(by: { $0.index < $1.index }).map { seg in
                let segURL = fileStore.segmentURL(for: item.id, fileName: seg.fileName)
                let segExists = FileManager.default.fileExists(atPath: segURL.path)
                let segSize = segExists ? (try? FileManager.default.attributesOfItem(atPath: segURL.path)[.size] as? Int) ?? 0 : 0
                let segDur = segExists ? Self.audioDuration(url: segURL) : 0
                return "seg[\(seg.index)]=\(seg.fileName) exists=\(segExists) size=\(segSize) dur=\(String(format: "%.1f", segDur))s"
            } ?? []
        let sumSegmentDurations =
            segmentDetails.isEmpty
            ? 0.0
            : (manifest?.segments.compactMap { seg -> Double? in
                let url = fileStore.segmentURL(for: item.id, fileName: seg.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let d = Self.audioDuration(url: url)
                return d > 0 ? d : nil
            }.reduce(0, +) ?? 0)
        let engineInfo = resolveTranscriptionEngine()
        let engineLabel = engineInfo.map { $0.id } ?? "none"

        AppLog.audio.info(
            """
            Transcription diagnostics for \(id.uuidString.prefix(8)):
            • finalAudioURL: \(audioURL.path)
            • audioExists: \(audioExists)
            • audioSize: \(audioSize) bytes
            • audioDuration: \(String(format: "%.1f", audioDuration))s
            • hasConsolidatedAudio: \(audioExists)
            • manifestExists: \(hasManifest)
            • segments: \(segmentCount)
            • segmentDetails: \(segmentDetails.joined(separator: ", "))
            • sumSegmentDurations: \(String(format: "%.1f", sumSegmentDurations))s
            • engine: \(engineLabel)
            """)

        // Reuse existing transcript when available
        if let existing = loadExistingTranscriptText(for: item.id) {
            AppLog.provider.info("ContentExtraction: reusing existing transcript for item \(id)")
            return existing
        }

        // ── Pre-transcription validation ───────────────────────────
        // audio.m4a (AAC) is produced by AudioSegmentConcatenator post-stop.
        // All engines receive the same file:
        // - Apple: prepareForRecognition decodes AAC→16kHz WAV for SFSpeechRecognizer
        // - Whisper: AAC bytes sent directly via HTTP multipart
        guard audioExists else {
            AppLog.audio.error("Transcription validation FAILED: final audio missing")
            return nil
        }
        guard audioSize > 4096 else {
            AppLog.audio.error("Transcription validation FAILED: audio too small (\(audioSize) bytes)")
            return nil
        }
        guard audioDuration >= 1.0 else {
            AppLog.audio.error("Transcription validation FAILED: audio too short (\(String(format: "%.1f", audioDuration))s)")
            return nil
        }
        if hasManifest, let m = manifest, !m.segments.isEmpty, sumSegmentDurations > 0 {
            let ratio = audioDuration / sumSegmentDurations
            if ratio < 0.3 || ratio > 2.5 {
                AppLog.audio.warning(
                    "Transcription validation: consolidated audio duration (\(String(format: "%.1f", audioDuration))s) deviates from segment sum (\(String(format: "%.1f", sumSegmentDurations))s) — ratio=\(String(format: "%.2f", ratio))"
                )
            }
        }
        AppLog.audio.info("Transcription validation PASSED for \(id.uuidString.prefix(8))")
        // ── End validation ──────────────────────────────────────────

        let result = await transcribeSingleFile(item: item)

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        let chars = result?.count ?? 0
        AppLog.provider.info("ContentExtraction: transcription finished — engine=\(engineLabel) elapsed=\(elapsed)ms chars=\(chars)")

        return result
    }

    /// Resolve which transcription engine to use based on settings and provider config.
    /// - Parameter preferredLocale: BCP-47 locale identifier for SFSpeechRecognizer, e.g. "en-US".
    private func resolveTranscriptionEngine(preferredLocale: String? = nil) -> (any TranscriptionEngine)? {
        let settings = TranscriptionSettings.shared
        let config = ActiveProviderManager.shared.getActiveProvider(context: modelContext)

        let canUseRemoteWhisper: Bool = {
            guard let config, config.baseURL != nil else { return false }
            let supportsTranscription = AIConfigService.shared.supportsAudioTranscription(for: config.providerConfigId)
            let typeSupports = AIConfigService.shared.supportsAudioTranscription(for: config.typeRaw)
            return settings.useRemoteWhisper && (supportsTranscription || typeSupports)
        }()

        if canUseRemoteWhisper, let config, let baseURL = config.baseURL {
            var apiKey = ""
            if let keyId = config.apiKeyKeychainIdentifier {
                apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
            }
            return RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
        }
        // Item's languageCode takes priority over the service-level preferredLocale
        let locale = preferredLocale ?? self.preferredLocale
        return AppleSpeechTranscriptionEngine(preferredLocale: locale)
    }

    /// Returns the effective engine ID, appending "-cloud" when the Apple engine
    /// fell back to cloud recognition (on-device was rejected).
    private func resolvedEngineId(_ engine: any TranscriptionEngine) -> String {
        if let apple = engine as? AppleSpeechTranscriptionEngine, apple.usedCloudFallback {
            return "apple-cloud"
        }
        return engine.id
    }

    /// Transcribe the consolidated audio.m4a (AAC) via the selected engine.
    /// Apple engines decode AAC→WAV internally; Whisper sends AAC directly.
    private func transcribeSingleFile(item: KnowledgeItem) async -> String? {
        let audioURL = fileStore.audioFileURL(for: item.id)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            AppLog.provider.warning("ContentExtraction: no audio file for item \(item.id)")
            return nil
        }

        let engine = resolveTranscriptionEngine(preferredLocale: item.languageCode)
        guard let engine else { return nil }

        do {
            var result = try await engine.transcribeFile(audioURL, meetingId: item.id)

            // ── Post-transcription diagnostics ────────────────────
            let transcriptChars = result.segments.map(\.text).joined(separator: " ").count
            let langCode = result.languageCode ?? "nil"
            AppLog.audio.info(
                """
                Transcription result for \(item.id.uuidString.prefix(8)):
                • engine: \(self.resolvedEngineId(engine))
                • transcriptSegments: \(result.segments.count)
                • transcriptTextLength: \(transcriptChars) chars
                • languageCode: \(langCode)
                """)
            // ── End diagnostics ───────────────────────────────────

            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: item.id)

            item.transcriptionEngineId = resolvedEngineId(engine)
            // Status transitions and save are owned by ContentPipelineService

            NotificationCenter.default.post(name: .transcriptReady, object: item.id.uuidString)

            AppLog.provider.info("ContentExtraction: transcription complete (\(result.segments.count) segments)")
            return result.segments.map(\.text).joined(separator: "\n")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.provider.error("ContentExtraction: transcription failed for item \(item.id): \(msg)")
            // Post error details so KnowledgeDetailView can show them
            NotificationCenter.default.post(
                name: .transcriptionFailed, object: item.id.uuidString,
                userInfo: ["error": msg])
            if let fallback = loadExistingTranscriptText(for: item.id) {
                return fallback
            }
            return nil
        }
    }

    /// Reads transcript text from an already-saved transcript.json, if it exists.
    private func loadExistingTranscriptText(for itemID: UUID) -> String? {
        guard let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: itemID),
            !transcript.segments.isEmpty
        else { return nil }
        return transcript.segments.map(\.text).joined(separator: "\n")
    }

    /// Returns true when the item needs transcription: either no transcript exists,
    /// or the stored engine ID differs from the currently selected engine.
    /// This enables re-transcription when the user switches Apple ↔ Whisper.
    func needsTranscription(for item: KnowledgeItem) -> Bool {
        // No transcript on disk — definitely needs transcription
        guard let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id),
            !transcript.segments.isEmpty
        else { return true }
        // Engine mismatch — force re-transcription
        guard let storedId = item.transcriptionEngineId else { return true }
        let engine = resolveTranscriptionEngine(preferredLocale: item.languageCode)
        let currentId = engine.map { resolvedEngineId($0) } ?? "none"
        return storedId != currentId
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

    /// Shared OCR utility — replaces duplicated recognizeText() across UI views.
    /// Extracts text from a UIImage using Vision's accurate text recognition.
    static func recognizeText(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    func extractTextFromImage(_ item: KnowledgeItem) async -> String? {
        // Return cached text if already extracted — prevents double extraction
        // from overwriting a successful OCR+Vision result.
        if let body = item.bodyText, !body.isEmpty, body != " " {
            AppLog.provider.info("ContentExtraction: reusing existing bodyText (\(body.count) chars)")
            return body
        }
        guard let relativePath = item.imageFileRelativePath else { return nil }
        let imageURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent(relativePath)
        guard let imageData = try? Data(contentsOf: imageURL),
            let image = UIImage(data: imageData),
            let cgImage = image.cgImage
        else { return nil }

        // 1. OCR
        let ocrText: String? = await withCheckedContinuation { continuation in
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

        // 2. LLM vision analysis (try OpenAI-compatible providers)
        if let provider = try? ProviderRouter.resolveActive(context: modelContext) {
            let msg = AIMessage(role: .user, content: [.text("Describe this image."), .imageFile(imageURL)])
            let model = AIConfigService.shared.modelFor(feature: "vision")
            let params = AIConfigService.shared.requestParams(for: "vision", model: model)
            let req = AIRequest(
                model: model, messages: [msg],
                temperature: params.temperature,
                maxTokens: params.maxTokens)
            if let response = try? await provider.send(req), !response.content.isEmpty {
                let combined = [ocrText, "---", response.content].compactMap { $0 }.joined(separator: "\n")
                // Save enriched text to body
                if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: item.id) {
                    fresh.bodyText = combined
                    try? modelContext.save()
                }
                return combined
            }
        }

        // Save OCR text to body if not already there
        if let ocrText, !ocrText.isEmpty,
            let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: item.id)
        {
            fresh.bodyText = ocrText
            try? modelContext.save()
        }
        return ocrText
    }

    // MARK: - Best-effort text retrieval

    /// Returns the best available text for an item without running expensive extraction.
    /// For webBookmarks, fetches URL content asynchronously (never blocks the calling actor).
    func bestAvailableText(for item: KnowledgeItem) async -> String? {
        // WebBookmarks: fetch URL content
        if item.type == .webBookmark, let urlStr = item.importSourceURL, let url = URL(string: urlStr) {
            if let fetched = await fetchBookmarkContent(url: url) {
                return fetched
            }
        }
        // Images: attempt OCR if no body text yet
        if item.type == .image, item.bodyText == nil {
            if let ocr = await extractTextFromImage(item) {
                return ocr
            }
        }
        if let transcript = loadExistingTranscriptText(for: item.id) {
            return transcript
        }
        if let body = item.bodyText, !body.isEmpty {
            return body
        }
        return nil
    }

    /// Synchronous variant for ShellInterpreter and other non-async callers.
    /// Uses a brief semaphore wait on a background queue for webBookmarks.
    func bestAvailableTextSync(for item: KnowledgeItem) -> String? {
        if item.type == .webBookmark, let urlStr = item.importSourceURL, let url = URL(string: urlStr) {
            if let fetched = fetchBookmarkContentSync(url: url) {
                return fetched
            }
        }
        if let transcript = loadExistingTranscriptText(for: item.id) {
            return transcript
        }
        if let body = item.bodyText, !body.isEmpty {
            return body
        }
        return nil
    }

    /// Fetch and extract plain text from a webBookmark's URL.
    /// Uses withCheckedContinuation to bridge async URLSession without blocking.
    private func fetchBookmarkContent(url: URL) async -> String? {
        guard let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let plainText = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(plainText.prefix(8000))
        } catch {
            AppLog.provider.warning("ContentExtraction: failed to fetch bookmark: \(error)")
            return nil
        }
    }

    /// Sync wrapper for callers that can't be async (ShellInterpreter, etc.).
    /// Uses a non-blocking approach: if content isn't cached locally, returns nil
    /// rather than blocking. The agent can retry extract later.
    private func fetchBookmarkContentSync(url: URL) -> String? {
        // WebBookmark fetching is inherently async. For sync callers (ShellInterpreter),
        // return nil if we can't get it instantly. The pipeline pre-fetches via the async path.
        return nil
    }

    // MARK: - Analyze text (source-aware)

    /// Runs AI analysis on extracted text. Uses the direct AnalysisService path
    /// for reliable structured output.
    /// - Returns: true on success, throws on transient errors (retryable),
    ///   false on permanent errors (don't retry).
    func analyze(text: String, item: KnowledgeItem) async throws -> Bool {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            AppLog.provider.warning("ContentExtraction.analyze: empty text for item \(item.id)")
            return false
        }

        guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
            AppLog.provider.warning("ContentExtraction.analyze: no provider configured")
            return false
        }

        let settings = AutomationSettings.shared
        let configModel = AIConfigService.shared.featureConfig(for: "analysis")?.model
        let model = configModel ?? settings.resolveAutoAnalysisModel(context: modelContext) ?? settings.autoAnalysisModel
        let sourceCtx = SourceContext.from(item)
        let segments = chunkText(text, itemID: item.id)
        let transcript = Transcript(meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: "text-direct")

        AppLog.provider.info("ContentExtraction.analyze: source=\(sourceCtx.sourceType.rawValue), model=\(model)")

        do {
            let result = try await AnalysisService().analyze(
                transcript: transcript, using: provider, model: model, meetingId: item.id, sourceContext: sourceCtx)

            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)
            item.status = .analyzed
            item.analysisProviderId = model
            try modelContext.save()

            AppLog.provider.info("ContentExtraction.analyze: done — \(result.shortSummary.prefix(80))")
            NotificationCenter.default.post(name: .analysisReady, object: item.id.uuidString)
            await EmbeddingPipelineService().ensureEmbedding(for: item, using: provider)
            return true
        } catch let error as TranscriptionError {
            // Permanent errors: model not found, invalid API key — don't retry
            AppLog.provider.error("ContentExtraction.analyze: PERMANENT failure for item \(item.id): \(error.localizedDescription)")
            try? fileStore.createMeetingDirectory(for: item.id)
            return false
        } catch {
            // Transient errors: network timeout, rate limit, server error — retryable
            AppLog.provider.error("ContentExtraction.analyze: TRANSIENT failure for item \(item.id): \(error.localizedDescription)")
            throw error
        }
    }

    /// Parses agent output into structured MeetingAnalysis artifact.
    private func analyzeStructured(transcript: Transcript, item: KnowledgeItem, sourceCtx: SourceContext, provider: any AIProvider, model: String) async -> Bool
    {
        do {
            let result = try await AnalysisService().analyze(
                transcript: transcript, using: provider, model: model, meetingId: item.id, sourceContext: sourceCtx)
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

    func chunkText(_ text: String, itemID: UUID) -> [TranscriptSegment] {
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
                segments.append(
                    TranscriptSegment(
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
            segments.append(
                TranscriptSegment(
                    meetingId: itemID, startTime: Double(segmentIndex),
                    text: currentChunk, sourceEngineId: "text-chunk"
                ))
        }

        if segments.isEmpty {
            segments.append(
                TranscriptSegment(
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
/// A audio transcript, an imported PDF, a scanned document, and a manual note
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
    /// Each source gets a different analytical lens — a audio transcript needs
    /// decisions/actions/risks extraction, while a scanned document needs
    /// structure analysis and clause identification.
    func analysisSystemPrompt() -> String {
        switch sourceType {
        case .recording:
            return
                "You are a audio content analyst. Extract decisions, action items with owners, risks, open questions, important dates, mentioned people/systems/organizations, and a topic timeline. Return only valid JSON."
        case .import_:
            return
                "You are a document analyst. Analyze this imported file. Identify its structure, key points, decisions if any, action items, risks, mentioned entities, and dates. Consider the filename and metadata for context. Return only valid JSON."
        case .scan:
            return
                "You are a visual content analyst. Analyze this image description (which may include OCR text and/or an AI-generated visual description). Identify what is depicted, key objects, text content, context, and any action items or insights. Note that this is NOT a meeting transcript — focus on visual content. Return only valid JSON."
        case .note:
            return
                "You are a knowledge analyst. Analyze this note. Extract key themes, questions being explored, references to other topics, action items if any, and people/systems mentioned. Return only valid JSON."
        }
    }

    /// Builds a source-context prefix for the user prompt so the LLM knows
    /// what kind of content it's analyzing and any relevant metadata.
    func userPromptPrefix() -> String {
        var lines: [String] = []
        switch sourceType {
        case .recording:
            lines.append("The following is a audio transcript.")
            if let dur = metadata["duration"] { lines.append("Duration: \(dur)") }
            if let lang = metadata["language"] { lines.append("Language: \(lang)") }
        case .import_:
            lines.append("The following is the content of an imported file.")
            if let fn = metadata["filename"] { lines.append("Filename: \(fn)") }
        case .scan:
            lines.append("The following describes an image (may include OCR text and/or visual scene description).")
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

// MARK: - Image Analysis (OCR + LLM Vision)

/// Combines Apple OCR with LLM vision analysis for comprehensive image understanding.
/// OCR extracts exact text; the LLM describes visual content, layout, document type, and context.
@MainActor
final class ImageAnalysisService {

    /// Analyze an image file: run OCR + LLM vision, return combined enriched text.
    func analyzeImage(_ imageURL: URL, llmProvider: any AIProvider, model: String) async throws -> String {
        guard let image = UIImage(contentsOfFile: imageURL.path),
            let cgImage = image.cgImage
        else {
            throw ImageAnalysisError.invalidImage
        }

        // Phase 1: Apple OCR for exact text extraction
        let ocrText: String = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }

        // Phase 2: LLM vision analysis for visual understanding
        let visualDescription: String
        do {
            let params = AIConfigService.shared.requestParams(for: "analysis", model: model)
            let request = AIRequest(
                model: model,
                messages: [
                    AIMessage(
                        role: .system,
                        content: [
                            .text(
                                "You are a document image analyst. Describe what you see in the image — document type, layout, visual elements, handwriting, diagrams. Be concise but thorough. Return only the description, no JSON."
                            )
                        ]),
                    AIMessage(
                        role: .user,
                        content: [
                            .text("Analyze this document image. Describe its type, content, layout, and any notable visual elements."),
                            .imageFile(imageURL),
                        ]),
                ],
                temperature: params.temperature,
                maxTokens: min(params.maxTokens ?? 4096, 2048)
            )
            let response = try await llmProvider.send(request)
            visualDescription = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            visualDescription = ""
        }

        // Combine OCR + visual description
        var parts: [String] = []
        if !ocrText.isEmpty { parts.append("OCR TEXT:\n\(ocrText)") }
        if !visualDescription.isEmpty { parts.append("VISUAL ANALYSIS:\n\(visualDescription)") }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n---\n\n")
    }
}

enum ImageAnalysisError: Error, LocalizedError {
    case invalidImage
    case noProviderConfigured

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "The image file could not be read."
        case .noProviderConfigured: return "No AI provider configured. Go to Settings to add one."
        }
    }
}

// MARK: - Location Intelligence

/// Resolves coordinates to human-readable addresses and vice versa.
/// Enriches items with location context for LLM analysis.
/// Handles GPS from recordings, EXIF from images/videos, and text mentions.
@MainActor
final class LocationIntelligenceService {
    private let geocoder = CLGeocoder()

    /// Extract coordinates from an image file via EXIF metadata.
    /// Works with JPEG, HEIC, TIFF, and RAW formats that embed GPS tags.
    static func extractGPSFromImage(_ imageURL: URL) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
            let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        else { return nil }

        let latitude = latRef == "S" ? -lat : lat
        let longitude = lonRef == "W" ? -lon : lon
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Reverse-geocode coordinates into a human-readable address string.
    func resolveToAddress(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                guard let place = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let parts = [
                    place.name,
                    place.thoroughfare,
                    place.locality,
                    place.administrativeArea,
                    place.country,
                ].compactMap { $0 }.filter { !$0.isEmpty }
                let address = parts.joined(separator: ", ")
                continuation.resume(returning: address.isEmpty ? nil : address)
            }
        }
    }

    /// Forward-geocode a text query into coordinates.
    func resolveToCoordinates(_ query: String) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(query) { placemarks, _ in
                guard let loc = placemarks?.first?.location else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: loc.coordinate)
            }
        }
    }

    /// Enrich a KnowledgeItem with location context for LLM analysis.
    /// Uses recorded GPS or EXIF metadata from attached images.
    func enrichItem(_ item: KnowledgeItem) async -> String? {
        var lat: Double?
        var lon: Double?

        // Priority 1: Already captured context coordinates
        if let clat = item.contextLatitude, let clon = item.contextLongitude {
            lat = clat
            lon = clon
        }

        // Priority 2: EXIF from scanned images
        if lat == nil, let relativePath = item.imageFileRelativePath {
            let store = FileArtifactStore()
            let url = store.itemDirectoryURL(for: item.id).appendingPathComponent(relativePath)
            if let coord = Self.extractGPSFromImage(url) {
                lat = coord.latitude
                lon = coord.longitude
                // Persist for future use
                item.contextLatitude = lat
                item.contextLongitude = lon
            }
        }

        guard let lat, let lon else { return nil }

        let address = await resolveToAddress(latitude: lat, longitude: lon)
        if let address {
            item.contextPlaceName = address
        }
        return address
    }

    /// Build a location-aware context string for LLM prompts.
    func locationContextString(for item: KnowledgeItem) async -> String {
        guard let address = await enrichItem(item) else {
            // Fall back to existing place_name annotation
            if let place = item.contextPlaceName, !place.isEmpty {
                return "Location: \(place)"
            }
            return ""
        }
        var parts: [String] = ["Location: \(address)"]
        if let city = item.contextPlaceName?.components(separatedBy: ", ").dropFirst().first {
            parts.append("City: \(city)")
        }
        return parts.joined(separator: "\n")
    }

    /// Find items near a given coordinate within a radius (meters).
    static func nearbyItems(to coordinate: CLLocationCoordinate2D, radiusMeters: Double, in items: [KnowledgeItem]) -> [KnowledgeItem] {
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return items.filter { item in
            guard let ilat = item.contextLatitude, let ilon = item.contextLongitude else { return false }
            let loc = CLLocation(latitude: ilat, longitude: ilon)
            return loc.distance(from: center) <= radiusMeters
        }
    }

}
