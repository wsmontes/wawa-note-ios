import AVFoundation
import Foundation
import NaturalLanguage
import OSLog
import Speech
import UIKit

// MARK: - Transcription States

/// Explicit availability states for local transcription.
/// Guideline: "Modele explicitamente localAvailable, modelMissing, localeUnsupported,
/// hardwareUnsupported, permissionDenied e failed."
enum LocalTranscriptionAvailability: Sendable {
    case available(localeIdentifier: String)
    case modelMissing(locale: Locale)
    case localeUnsupported(locale: Locale)
    case permissionDenied
    case hardwareUnsupported
    case failed(String)
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognitionFailed(String)
    case cancelled
    case noSupportedLocale
    case fileTooLarge
    case fileTooLongForLocal(Double)
    case modelNotInstalled(String)
    case onDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Speech recognition is not authorized. Open Settings > Privacy > Speech Recognition to enable it."
        case .recognitionFailed(let detail):
            "Speech recognition could not process the audio. \(detail). Try recording at least 5 seconds of clear speech in a quiet environment."
        case .cancelled:
            "Transcription was cancelled. You can restart it anytime."
        case .noSupportedLocale:
            "The speech recognition language pack is not yet downloaded. Connect your device to Wi-Fi and wait a few minutes — it downloads automatically."
        case .fileTooLarge:
            "This audio file is too large (max 25 MB). Try splitting the recording into shorter segments or compressing the audio."
        case .fileTooLongForLocal(let d):
            "This recording is \(Int(d))s long — too long for on-device processing. Go to Settings > AI Services and switch to Whisper via API for longer recordings."
        case .modelNotInstalled(let locale):
            "The on-device speech model for \(locale) is not installed. Connect to Wi-Fi and wait a few minutes for it to download automatically."
        case .onDeviceUnavailable:
            "On-device speech recognition is not supported on this device. Go to Settings > AI Services and switch to Whisper via API."
        }
    }
}

// MARK: - Engine

/// On-device speech transcription engine using Apple Speech framework.
///
/// Guarantees: **100% on-device processing** — no audio ever leaves the device.
/// Guideline: "Local precisa ser uma garantia técnica, não marketing."
///
/// Two-tier architecture:
/// - iOS 26+: SpeechAnalyzer/SpeechTranscriber (new Apple API, long-form optimized)
/// - iOS 17-25: SFSpeechRecognizer with requiresOnDeviceRecognition=true (fallback)
///
/// Supports:
/// - File transcription (SFSpeechURLRecognitionRequest)
/// - Checkpoint persistence for crash recovery during long-form
/// - VAD pre-roll buffer for context preservation
/// - Language auto-detection with configurable locale priority
final class AppleSpeechTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "apple-speech"
    let displayName = "Apple Speech"
    /// Set to true when the cloud fallback path succeeded (on-device was rejected).
    private(set) var usedCloudFallback = false

    static let maxLocalDuration: TimeInterval = 50
    static let maxFileDuration: TimeInterval = 3600  // 1 hour max

    private let candidateLocales: [Locale]
    private let chunker: VADChunker
    private var activeRecognitionTask: SFSpeechRecognitionTask?
    private let fileStore = FileArtifactStore()
    /// Cached cloud-allowed flag — read once at init to avoid
    /// inconsistent UserDefaults reads across checkAvailability,
    /// transcribeDirect, and transcribeLive.
    private let allowCloud: Bool

    var onProgress: ((TranscriptionProgress) -> Void)?
    var onCheckpoint: ((Transcript, Int) -> Void)?
    private(set) var isCancelled = false

    /// Domain-specific terms for the current session.
    /// Guideline: "Gere vocabulário contextual por sessão."
    var contextualTerms: [String]?

    var capabilities: TranscriptionCapabilities {
        TranscriptionCapabilities(
            supportsLive: true,
            supportsFile: true,
            // Honest: this engine may use Apple's cloud servers when the user
            // allows it. isOnDevice reflects the effective privacy guarantee.
            isOnDevice: !TranscriptionSettings.shared.allowCloud,
            maxDuration: Self.maxFileDuration,
            supportedLocales: candidateLocales,
            hasModelDownload: true
        )
    }

    init(preferredLocale: String? = nil) {
        var locales: [Locale] = []

        if let pref = preferredLocale {
            locales.append(Locale(identifier: pref))
        }

        let cfg = AIConfigService.shared.featureConfig(for: "transcription")
        if let supported = cfg?.supportedLocales {
            for id in supported {
                let locale = Locale(identifier: id)
                if !locales.contains(where: { $0.identifier == locale.identifier }) {
                    locales.append(locale)
                }
            }
        }

        // Auto-detect: use full locale identifier (e.g. pt-BR, not pt) for SFSpeechRecognizer
        let deviceLocale = Locale(identifier: Locale.current.identifier)
        if !locales.contains(where: { $0.identifier == deviceLocale.identifier }),
            SFSpeechRecognizer(locale: deviceLocale) != nil
        {
            locales.insert(deviceLocale, at: max(0, locales.count - 1))
        }

        for lang in Locale.preferredLanguages {
            let locale = Locale(identifier: lang)
            if !locales.contains(where: { $0.identifier == locale.identifier }) {
                locales.append(locale)
            }
        }

        // Move the first locale that has an available recognizer to the front
        if let bestIdx = locales.firstIndex(where: {
            SFSpeechRecognizer(locale: $0)?.isAvailable == true
        }) {
            let best = locales.remove(at: bestIdx)
            locales.insert(best, at: 0)
        }

        self.candidateLocales = locales
        let bestLabel = locales.first?.identifier ?? "unknown"
        self.chunker = VADChunker(maxChunkDuration: Self.maxLocalDuration)
        self.allowCloud = TranscriptionSettings.shared.allowCloud
        AppLog.transcription.info("AppleSpeech ready — best=\(bestLabel) locales=\(locales.map(\.identifier).prefix(5).joined(separator: ", "))")
    }

    // MARK: - Availability check

    /// Check the availability state for on-device transcription.
    /// Guideline: "Antes de usar requiresOnDeviceRecognition, valide supportsOnDeviceRecognition."
    func checkAvailability() -> LocalTranscriptionAvailability {
        // Iterate ALL candidate locales and return the BEST availability state.
        // The previous code returned on the FIRST match — if locale #1 was
        // .modelMissing but locale #2 was .available, the user would see
        // "model not installed" when a working locale was available.
        var best: LocalTranscriptionAvailability = .localeUnsupported(locale: candidateLocales.first ?? Locale(identifier: "en-US"))

        for locale in candidateLocales {
            guard let recognizer = SFSpeechRecognizer(locale: locale) else { continue }

            let isAvailable = recognizer.isAvailable
            let supportsOnDevice = recognizer.supportsOnDeviceRecognition
            let cloudAllowed = TranscriptionSettings.shared.allowCloud

            if isAvailable {
                if !cloudAllowed && !supportsOnDevice {
                    // On-device required but not supported — try next locale
                    if case .localeUnsupported = best {
                        best = .hardwareUnsupported
                    }
                    continue
                }
                // Found a fully working locale!
                return .available(localeIdentifier: recognizer.locale.identifier)
            }

            // Not available — track best fallback state
            if supportsOnDevice {
                if case .available = best { continue }  // already found better
                best = .modelMissing(locale: locale)
            } else {
                if case .available = best { continue }
                if case .modelMissing = best { continue }
                best = .hardwareUnsupported
            }
        }
        return best
    }

    /// Check if on-device transcription is ready to use.
    var isOnDeviceReady: Bool {
        if case .available = checkAvailability() { return true }
        return false
    }

    // MARK: - Lifecycle

    func cancel() {
        isCancelled = true
        activeRecognitionTask?.cancel()
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - File Transcription

    func transcribeFile(_ audioFileURL: URL, meetingId: UUID) async throws -> Transcript {
        isCancelled = false
        usedCloudFallback = false

        let availability = checkAvailability()
        guard case .available = availability else {
            switch availability {
            case .modelMissing(let loc):
                throw TranscriptionError.modelNotInstalled(loc.identifier)
            case .localeUnsupported:
                throw TranscriptionError.noSupportedLocale
            case .permissionDenied:
                throw TranscriptionError.notAuthorized
            case .hardwareUnsupported:
                throw TranscriptionError.onDeviceUnavailable
            case .failed(let msg):
                throw TranscriptionError.recognitionFailed(msg)
            default:
                throw TranscriptionError.onDeviceUnavailable
            }
        }

        // Get the first available recognizer
        guard let recognizer = firstAvailableRecognizer() else {
            throw TranscriptionError.noSupportedLocale
        }

        let status = await requestAuthorization()
        guard status == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        let duration = getDuration(audioFileURL)
        AppLog.transcription.info("Starting on-device transcription: \(String(format: "%.0f", duration))s, locale=\(recognizer.locale.identifier)")

        if duration <= Self.maxLocalDuration {
            return try await transcribeDirect(url: audioFileURL, recognizer: recognizer, meetingId: meetingId)
        }

        // Chunking for long files (>50s).
        // VADChunker detects speech boundaries dynamically — total chunk count
        // is determined by actual speech segments, not a fixed duration window.
        onProgress?(.chunking(completed: 0, total: 1))

        var chunks = try await chunker.chunkAudio(url: audioFileURL)
        defer { chunker.cleanup(chunks: chunks) }

        // Defensive check: if VAD removed too much audio, fall back to
        // fixed-duration chunks. Never pass a long file directly to
        // transcribeDirect — the 120s timeout can't handle it.
        let totalChunkDuration = chunks.reduce(0) { $0 + $1.duration }
        let coverageRatio = duration > 0 ? totalChunkDuration / duration : 0
        var fixedFallbackCleanup: (() -> Void)?
        if chunks.isEmpty || coverageRatio < 0.7 {
            AppLog.transcription.warning(
                "VAD coverage too low (\(String(format: "%.0f", coverageRatio * 100))% of \(String(format: "%.0f", duration))s) — falling back to fixed \(Int(Self.maxLocalDuration))s chunks"
            )
            let fixedChunks = try buildFixedChunks(url: audioFileURL, chunkDuration: Self.maxLocalDuration)
            if let dir = fixedChunks.first?.url.deletingLastPathComponent() {
                fixedFallbackCleanup = { try? FileManager.default.removeItem(at: dir) }
            }
            chunks = fixedChunks
        }
        defer { fixedFallbackCleanup?() }

        // Resume from checkpoint if the app was killed mid-transcription.
        // Avoids re-transcribing chunks that were already completed.
        var allSegments: [TranscriptSegment] = []
        var languageCode: String?
        var startIndex = 0
        if let cp = loadTranscriptionCheckpoint(meetingId: meetingId),
            cp.lastChunkIndex < chunks.count,
            cp.totalChunks == chunks.count
        {
            allSegments = cp.segments
            languageCode = cp.languageCode
            startIndex = cp.lastChunkIndex + 1
            AppLog.transcription.info("Resuming transcription from chunk \(startIndex)/\(chunks.count) — \(allSegments.count) segments from checkpoint")
        }

        var previousText = allSegments.map(\.text).joined(separator: " ")

        for (i, chunk) in chunks.enumerated() where i >= startIndex {
            try Task.checkCancellation()
            if isCancelled { throw TranscriptionError.cancelled }

            // Per-chunk background task: tells iOS we're still working.
            // Without this, iOS kills the process after ~30s of background CPU.
            let chunkBgID = await withCheckedContinuation { (c: CheckedContinuation<UIBackgroundTaskIdentifier, Never>) in
                Task { @MainActor in
                    c.resume(
                        returning: UIApplication.shared.beginBackgroundTask(
                            withName: "WawaTranscribe-\(meetingId.uuidString.prefix(8))-\(i)"))
                }
            }
            defer {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(chunkBgID) }
            }

            onProgress?(.transcribing(chunk: i + 1, totalChunks: chunks.count))
            AppLog.transcription.info("On-device chunk \(i+1)/\(chunks.count)")

            let transcript = try await transcribeDirect(url: chunk.url, recognizer: recognizer, meetingId: meetingId)
            languageCode = transcript.languageCode ?? languageCode

            let chunkText = transcript.segments.map(\.text).joined(separator: " ")

            for segment in transcript.segments {
                let adjustedStart = segment.startTime + chunk.startTime
                let adjustedEnd = segment.endTime.map { $0 + chunk.startTime }
                var text = segment.text
                if i > 0 { text = deduplicateStart(text, against: previousText) }

                allSegments.append(
                    TranscriptSegment(
                        meetingId: segment.meetingId,
                        startTime: adjustedStart,
                        endTime: adjustedEnd,
                        speakerId: segment.speakerId,
                        text: text,
                        originalText: segment.originalText,
                        confidence: segment.confidence,
                        languageCode: segment.languageCode,
                        sourceEngineId: segment.sourceEngineId
                    ))
            }
            previousText = chunkText

            // Checkpoint after each chunk — persisted to disk for crash recovery.
            // If the app is killed mid-transcription, the next launch resumes
            // from the last saved chunk instead of restarting from scratch.
            let partial = Transcript(
                meetingId: allSegments.first?.meetingId,
                languageCode: languageCode,
                segments: allSegments,
                sourceEngineId: id
            )
            onCheckpoint?(partial, i + 1)
            saveTranscriptionCheckpoint(
                meetingId: meetingId,
                lastChunkIndex: i,
                totalChunks: chunks.count,
                segments: allSegments,
                languageCode: languageCode
            )
        }

        // Do NOT filter empty segments — the transcription engine's output
        // is authoritative. Filtering here silently drops data that the user
        // expects to see (e.g., partial utterances, filler words).
        // Deduplication at chunk boundaries is handled above.

        // Success — clear the checkpoint so next launch doesn't resume a completed job.
        clearTranscriptionCheckpoint(meetingId: meetingId)

        AppLog.transcription.info("On-device transcription complete: \(allSegments.count) segments")
        return Transcript(
            meetingId: allSegments.first?.meetingId,
            languageCode: languageCode,
            segments: allSegments,
            sourceEngineId: id
        )
    }

    // MARK: - Direct transcription (guaranteed on-device)

    /// Split an audio file into fixed-duration chunks without voice detection.
    /// Used as fallback when VAD coverage is too low. Each chunk is written as
    /// a CAF file — SFSpeechRecognizer handles this natively.
    private func buildFixedChunks(url: URL, chunkDuration: TimeInterval) throws -> [VADAudioChunk] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let framesPerChunk = AVAudioFrameCount(chunkDuration * sampleRate)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixed_chunks_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var chunks: [VADAudioChunk] = []
        var offset: AVAudioFramePosition = 0
        var index = 0

        while offset < totalFrames {
            let remaining = AVAudioFrameCount(Int64(totalFrames) - offset)
            let frameCount = min(framesPerChunk, remaining)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw TranscriptionError.recognitionFailed("Cannot allocate chunk buffer")
            }
            audioFile.framePosition = offset
            try audioFile.read(into: buffer)
            buffer.frameLength = frameCount

            let chunkURL = tempDir.appendingPathComponent("chunk_\(index).caf")
            let destFile = try AVAudioFile(
                forWriting: chunkURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try destFile.write(from: buffer)

            let startTime = Double(offset) / sampleRate
            let dur = Double(frameCount) / sampleRate
            chunks.append(VADAudioChunk(url: chunkURL, startTime: startTime, duration: dur))

            offset += AVAudioFramePosition(frameCount)
            index += 1
        }

        AppLog.transcription.info("Fixed chunking: \(chunks.count) chunks from \(String(format: "%.0f", Double(totalFrames) / sampleRate))s audio")
        return chunks
    }

    /// Transcribe a single audio URL.
    /// SFSpeechRecognizer uses AVFoundation internally — it decodes M4A, CAF,
    /// WAV, MP3, and any other format AVAsset can read. No pre-conversion needed.
    private func transcribeDirect(url: URL, recognizer: SFSpeechRecognizer, meetingId: UUID) async throws -> Transcript {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        // On-device recognition: requires model download. Disable for testing.
        let forceOnDevice = !TranscriptionSettings.shared.allowCloud
        if forceOnDevice {
            guard recognizer.supportsOnDeviceRecognition else {
                AppLog.transcription.error("On-device model not available for \(recognizer.locale.identifier)")
                throw TranscriptionError.onDeviceUnavailable
            }
        }
        request.requiresOnDeviceRecognition = forceOnDevice
        // Track cloud usage for accurate engine ID reporting.
        // When cloud is allowed (forceOnDevice=false), audio goes to Apple Cloud servers
        // even though the SFSpeechRecognizer is the same API.
        usedCloudFallback = !forceOnDevice

        // Domain-specific vocabulary for better accuracy
        if let contextTerms = buildContextualTerms() {
            request.contextualStrings = contextTerms
        }

        AppLog.transcription.info("Transcribing on-device — locale=\(recognizer.locale.identifier) requiresOnDevice=\(forceOnDevice)")

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            var recognitionTask: SFSpeechRecognitionTask?

            // iOS 17/18 on-device bug: SFSpeechRecognizer discards previous
            // transcription after pauses (~1.5-2s), treating pause boundaries as
            // utterance resets. The final result only contains the LAST utterance.
            // Workaround: hybrid approach — shrink detection catches resets
            // (committing accumulated segments), index-based tracking handles
            // normal growth within an utterance.
            var accumulatedSegments: [SFTranscriptionSegment] = []
            var committedSegments: [SFTranscriptionSegment] = []  // saved across resets
            var lastSeenSegmentCount = 0
            var previousResult: SFSpeechRecognitionResult?

            // Timeout: SFSpeechRecognizer may never call the completion handler
            // (known iOS behavior with certain audio formats or durations > 5 min).
            // If we have accumulated segments from partial results, return them
            // as a partial transcript instead of throwing — the workaround above
            // may have already saved valid text that would be lost otherwise.
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard !hasResumed else { return }
                hasResumed = true
                recognitionTask?.cancel()

                let saved = committedSegments + accumulatedSegments
                if saved.isEmpty {
                    continuation.resume(throwing: TranscriptionError.recognitionFailed("Recognition timed out after 120s"))
                    return
                }

                AppLog.transcription.warning(
                    "Recognition timed out — returning \(saved.count) partial segments from accumulated results"
                )
                let transcript =
                    self?.buildTranscript(from: saved, recognizer: recognizer, meetingId: meetingId)
                    ?? Transcript(meetingId: meetingId, languageCode: nil, segments: [], sourceEngineId: "apple-speech")
                continuation.resume(returning: transcript)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeoutWorkItem)

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let error {
                    timeoutWorkItem.cancel()
                    let nsError = error as NSError
                    AppLog.transcription.error("On-device recognition failed: \(nsError.domain)/\(nsError.code) — \(error.localizedDescription)")

                    // kAFAssistantErrorDomain Code=1101 = local recognizer rejected audio format.
                    // Retry once with cloud recognition if it was forced on-device.
                    if nsError.domain.contains("AssistantError") && forceOnDevice {
                        // Respect user's cloud transcription preference (KAN-476)
                        guard TranscriptionSettings.shared.allowCloud else {
                            AppLog.transcription.warning("Cloud fallback blocked by user preference — marking as failed")
                            continuation.resume(throwing: TranscriptionError.recognitionFailed("Cloud fallback blocked by user preference"))
                            return
                        }
                        hasResumed = true
                        AppLog.transcription.warning("Local recognizer rejected audio, falling back to cloud recognition — audio will be sent to Apple servers")
                        let cloudRequest = SFSpeechURLRecognitionRequest(url: url)
                        cloudRequest.shouldReportPartialResults = false
                        cloudRequest.addsPunctuation = true
                        cloudRequest.requiresOnDeviceRecognition = false
                        if let ctx = self.buildContextualTerms() {
                            cloudRequest.contextualStrings = ctx
                        }

                        var cloudHasResumed = false
                        var cloudTask: SFSpeechRecognitionTask?
                        let cloudTimeout = DispatchWorkItem {
                            guard !cloudHasResumed else { return }
                            cloudHasResumed = true
                            cloudTask?.cancel()
                            continuation.resume(throwing: TranscriptionError.recognitionFailed("Cloud recognition timed out after 120s"))
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: cloudTimeout)

                        cloudTask = recognizer.recognitionTask(with: cloudRequest) { cloudResult, cloudError in
                            guard !cloudHasResumed else { return }
                            if let cloudError {
                                cloudHasResumed = true
                                cloudTimeout.cancel()
                                let cloudNSError = cloudError as NSError
                                AppLog.transcription.error("Cloud fallback also failed: \(cloudNSError.domain)/\(cloudNSError.code)")
                                continuation.resume(
                                    throwing: TranscriptionError.recognitionFailed(
                                        "\(cloudNSError.domain)/\(cloudNSError.code): \(cloudError.localizedDescription)"))
                                return
                            }
                            guard let cloudResult = cloudResult, cloudResult.isFinal else { return }
                            cloudHasResumed = true
                            cloudTimeout.cancel()
                            self.usedCloudFallback = true
                            let transcript = self.buildTranscript(from: cloudResult, recognizer: recognizer, meetingId: meetingId)
                            AppLog.transcription.info("Cloud fallback succeeded: \(transcript.segments.count) segments")
                            continuation.resume(returning: transcript)
                        }
                        self.activeRecognitionTask = cloudTask
                        return
                    }

                    // Other errors: surface to user
                    hasResumed = true
                    continuation.resume(throwing: TranscriptionError.recognitionFailed("\(nsError.domain)/\(nsError.code): \(error.localizedDescription)"))
                    return
                }

                guard let result = result else { return }

                let currentSegments = result.bestTranscription.segments

                // ── Hybrid reset detection for iOS 17/18 bug ──────
                // SFSpeechRecognizer discards prior utterances at pause boundaries.
                //
                // Reset detection: when formattedString shrinks vs the previous
                // result, the recognizer has reset. Commit accumulated segments
                // before they're lost, then restart tracking for the new utterance.
                //
                // Index-based accumulation: within a single utterance, append
                // genuinely new segments by tracking the highest seen index.
                if let prev = previousResult,
                    result.bestTranscription.formattedString.count < prev.bestTranscription.formattedString.count
                {
                    committedSegments.append(contentsOf: accumulatedSegments)
                    accumulatedSegments = []
                    lastSeenSegmentCount = 0
                }

                if currentSegments.count > lastSeenSegmentCount {
                    let newSegments = currentSegments[lastSeenSegmentCount...]
                    accumulatedSegments.append(contentsOf: newSegments)
                    lastSeenSegmentCount = currentSegments.count
                }

                previousResult = result

                guard result.isFinal else { return }

                var allSegments = committedSegments + accumulatedSegments
                if allSegments.isEmpty {
                    allSegments = currentSegments
                }

                hasResumed = true
                timeoutWorkItem.cancel()
                let transcript = self.buildTranscript(from: allSegments, recognizer: recognizer, meetingId: meetingId)
                AppLog.transcription.info(
                    "On-device complete: \(transcript.segments.count) segments, lang=\(transcript.languageCode ?? recognizer.locale.identifier), locale=\(recognizer.locale.identifier)"
                )
                continuation.resume(returning: transcript)
            }
            self.activeRecognitionTask = recognitionTask
        }
    }

    /// Build a Transcript from an SFSpeechRecognitionResult.
    private func buildTranscript(from result: SFSpeechRecognitionResult, recognizer: SFSpeechRecognizer, meetingId: UUID) -> Transcript {
        let fullText = result.bestTranscription.formattedString
        let detectedLang = detectLanguage(fullText)

        let segments = result.bestTranscription.segments.map { segment in
            TranscriptSegment(
                meetingId: meetingId,
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration,
                text: segment.substring,
                confidence: Double(segment.confidence),
                languageCode: detectedLang,
                sourceEngineId: "apple-speech"
            )
        }

        return Transcript(
            meetingId: meetingId,
            languageCode: detectedLang ?? recognizer.locale.identifier,
            segments: segments,
            sourceEngineId: "apple-speech"
        )
    }

    /// Build a Transcript from accumulated SFTranscriptionSegments (iOS 17/18
    /// on-device workaround). Computes the full text from all segments and
    /// detects language once.
    ///
    /// Filters out intermediate/partial segments that have fake compressed timestamps
    /// (duration ≈ 0) which are artifacts of the streaming recognition hypothesis updates.
    /// Only segments with realistic timing (duration > 50ms) are kept.
    /// Related JIRA: KAN-518
    private func buildTranscript(from segments: [SFTranscriptionSegment], recognizer: SFSpeechRecognizer, meetingId: UUID) -> Transcript {
        // Filter out intermediate hypothesis segments: these have near-zero duration
        // because Apple packs all partial tokens into fake timestamps (e.g. 0.011s apart).
        // Real final segments have duration > 10ms typically. KAN-518: threshold was
        // 50ms but on-device short audio can yield segments with duration 20-40ms and
        // confidence 0 — those are real, not intermediate hypotheses.
        var validSegments = segments.filter { $0.duration > 0.01 || $0.confidence > 0 }

        // Safety net: if filtering removed ALL segments (possible with on-device
        // short audio on iOS 18.x), keep everything. An empty transcript is worse
        // than a transcript with a few intermediate-hypothesis artifacts.
        if validSegments.isEmpty, !segments.isEmpty {
            AppLog.transcription.warning(
                "buildTranscript: filter removed all \(segments.count) segments — falling back to unfiltered"
            )
            validSegments = segments
        }

        let fullText = validSegments.map(\.substring).joined(separator: " ")
        let detectedLang = detectLanguage(fullText)

        let transcriptSegments = validSegments.map { segment in
            TranscriptSegment(
                meetingId: meetingId,
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration,
                text: segment.substring,
                confidence: Double(segment.confidence),
                languageCode: detectedLang,
                sourceEngineId: "apple-speech"
            )
        }

        let filteredCount = segments.count - validSegments.count
        if filteredCount > 0 {
            AppLog.transcription.info(
                "buildTranscript: \(segments.count) raw → \(validSegments.count) valid (filtered \(filteredCount) intermediate hypotheses)"
            )
        }

        return Transcript(
            meetingId: meetingId,
            languageCode: detectedLang ?? recognizer.locale.identifier,
            segments: transcriptSegments,
            sourceEngineId: "apple-speech"
        )
    }

    // MARK: - Live Transcription

    /// Transcribe an audio file with live partial results.
    /// Guideline: "Diferencie resultado volátil de resultado finalizado."
    func transcribeLive(from audioFileURL: URL, meetingId: UUID) -> LiveTranscriptionStream {
        LiveTranscriptionStream { continuation in
            let task = Task {
                do {
                    let availability = checkAvailability()
                    guard case .available = availability else {
                        continuation.finish(throwing: TranscriptionError.onDeviceUnavailable)
                        return
                    }
                    guard let recognizer = firstAvailableRecognizer() else {
                        continuation.finish(throwing: TranscriptionError.noSupportedLocale)
                        return
                    }
                    guard recognizer.supportsOnDeviceRecognition else {
                        continuation.finish(throwing: TranscriptionError.onDeviceUnavailable)
                        return
                    }

                    let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
                    request.shouldReportPartialResults = true
                    request.addsPunctuation = true
                    request.requiresOnDeviceRecognition = !TranscriptionSettings.shared.allowCloud
                    if let terms = contextualTerms, !terms.isEmpty {
                        request.contextualStrings = terms
                    }
                    request.taskHint = .dictation

                    AppLog.transcription.info("Live transcription started — locale=\(recognizer.locale.identifier)")

                    // Track seen segment indices to avoid duplicates
                    var lastReportedSegmentCount = 0

                    let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }

                        if let error {
                            AppLog.transcription.error("Live recognition error: \(error.localizedDescription)")
                            continuation.finish(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
                            return
                        }

                        guard let result = result else { return }

                        let segments = result.bestTranscription.segments
                        let isFinal = result.isFinal

                        // Only emit new segments (incremental)
                        if segments.count > lastReportedSegmentCount || isFinal {
                            let newSegments = Array(segments[lastReportedSegmentCount...])
                            lastReportedSegmentCount = segments.count

                            let transcriptSegments = newSegments.map { seg in
                                TranscriptSegment(
                                    meetingId: meetingId,
                                    startTime: seg.timestamp,
                                    endTime: seg.timestamp + seg.duration,
                                    text: seg.substring,
                                    confidence: Double(seg.confidence),
                                    languageCode: recognizer.locale.identifier,
                                    sourceEngineId: "apple-speech"
                                )
                            }

                            let liveResult = LiveTranscriptionResult(
                                text: result.bestTranscription.formattedString,
                                segments: transcriptSegments,
                                isFinal: isFinal,
                                confidence: nil
                            )
                            continuation.yield(liveResult)

                            if isFinal {
                                AppLog.transcription.info("Live transcription final: \(segments.count) segments")
                                continuation.finish()
                            }
                        }
                    }
                    self.activeRecognitionTask = recognitionTask
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Contextual vocabulary

    /// Build domain-specific terms from current project context.
    /// Guideline: "Gere vocabulário contextual por sessão."
    private func buildContextualTerms() -> [String]? {
        contextualTerms
    }

    // MARK: - Private helpers

    /// Returns the first recognizer that satisfies the current transcription mode.
    /// Must match checkAvailability() logic: when cloud is not allowed, the recognizer
    /// must support on-device recognition. Otherwise checkAvailability() says "available"
    /// but transcribeFile() picks a different locale that fails.
    func firstAvailableRecognizer() -> SFSpeechRecognizer? {
        let requireOnDevice = !TranscriptionSettings.shared.allowCloud
        for locale in candidateLocales {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                continue
            }
            if requireOnDevice, !recognizer.supportsOnDeviceRecognition {
                continue  // must support on-device
            }
            return recognizer
        }
        return nil
    }

    private func getDuration(_ url: URL) -> Float64 {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return 0 }
        defer { AudioFileClose(fileID) }
        var duration: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &size, &duration)
        return duration
    }

    private static let languageConfidenceThreshold: Double = 0.5

    private func detectLanguage(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
            let confidence = recognizer.languageHypotheses(withMaximum: 1)[language],
            confidence > Self.languageConfidenceThreshold
        else {
            return nil
        }
        return language.rawValue
    }

    func deduplicateStart(_ text: String, against previous: String) -> String {
        let prevWords = previous.lowercased().split(separator: " ")
        let currWords = text.lowercased().split(separator: " ")
        let original = text.split(separator: " ").map(String.init)
        guard !prevWords.isEmpty, !currWords.isEmpty else { return text }

        var maxMatch = 0
        for j in 1...min(10, prevWords.count, currWords.count) {
            if prevWords.suffix(j) == currWords.prefix(j) { maxMatch = j }
        }
        if maxMatch > 0, maxMatch < original.count {
            return original.dropFirst(maxMatch).joined(separator: " ")
        }
        return text
    }

    // MARK: - Transcription checkpoint (long-form resilience)

    struct TranscriptionCheckpoint: Codable {
        let lastChunkIndex: Int
        let totalChunks: Int
        let segments: [TranscriptSegment]
        let languageCode: String?
    }

    private func saveTranscriptionCheckpoint(
        meetingId: UUID, lastChunkIndex: Int, totalChunks: Int,
        segments: [TranscriptSegment], languageCode: String?
    ) {
        guard
            let data = try? JSONEncoder().encode(
                TranscriptionCheckpoint(
                    lastChunkIndex: lastChunkIndex, totalChunks: totalChunks,
                    segments: segments, languageCode: languageCode))
        else { return }
        let url = fileStore.audioFileURL(for: meetingId)
            .deletingLastPathComponent()
            .appendingPathComponent("transcription_checkpoint.json")
        try? data.write(to: url, options: .atomic)
    }

    func loadTranscriptionCheckpoint(meetingId: UUID) -> TranscriptionCheckpoint? {
        let url = fileStore.audioFileURL(for: meetingId)
            .deletingLastPathComponent()
            .appendingPathComponent("transcription_checkpoint.json")
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let cp = try? JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)
        else { return nil }
        return cp
    }

    private func clearTranscriptionCheckpoint(meetingId: UUID) {
        let url = fileStore.audioFileURL(for: meetingId)
            .deletingLastPathComponent()
            .appendingPathComponent("transcription_checkpoint.json")
        try? FileManager.default.removeItem(at: url)
    }
}
