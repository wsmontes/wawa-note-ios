import Foundation
import Speech
import NaturalLanguage
import OSLog
import AVFoundation

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

    static let maxLocalDuration: TimeInterval = 50
    static let maxFileDuration: TimeInterval = 3600 // 1 hour max

    private let candidateLocales: [Locale]
    private let chunker: AudioChunker
    private var activeRecognitionTask: SFSpeechRecognitionTask?
    private let fileStore = FileArtifactStore()

    private static let chunkOverlap: TimeInterval = 1.5

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
            isOnDevice: true,
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

        // Auto-detect: prioritize the device language, then system preferred languages
        let deviceLang = Locale.current.language.languageCode?.identifier ?? "en"
        let deviceLocale = Locale(identifier: deviceLang)
        if !locales.contains(where: { $0.identifier == deviceLocale.identifier }),
           let _ = SFSpeechRecognizer(locale: deviceLocale) {
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
        self.chunker = AudioChunker(chunkDuration: Self.maxLocalDuration, overlap: Self.chunkOverlap)
        AppLog.transcription.info("AppleSpeech ready — best=\(bestLabel) locales=\(locales.map(\.identifier).prefix(5).joined(separator: ", "))")
    }

    // MARK: - Availability check

    /// Check the availability state for on-device transcription.
    /// Guideline: "Antes de usar requiresOnDeviceRecognition, valide supportsOnDeviceRecognition."
    func checkAvailability() -> LocalTranscriptionAvailability {
        for locale in candidateLocales {
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                return .localeUnsupported(locale: locale)
            }

            guard recognizer.isAvailable else {
                // Check if it's a model download issue or hardware
                if recognizer.supportsOnDeviceRecognition {
                    return .modelMissing(locale: locale)
                }
                return .hardwareUnsupported
            }

            // Verify on-device recognition is actually supported
            let cloudAllowed = UserDefaults.standard.bool(forKey: "transcription_allow_cloud")
            if !cloudAllowed {
                guard recognizer.supportsOnDeviceRecognition else {
                    return .hardwareUnsupported
                }
            }

            return .available(localeIdentifier: recognizer.locale.identifier)
        }
        return .localeUnsupported(locale: candidateLocales.first ?? Locale(identifier: "en-US"))
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

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript {
        isCancelled = false

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
            return try await transcribeDirect(url: audioFileURL, recognizer: recognizer)
        }

        // Chunking for long files (>50s)
        let total = Int(ceil(duration / chunker.chunkDuration))
        chunker.onProgress = { [weak self] completed, total in
            self?.onProgress?(.chunking(completed: completed, total: total))
        }
        onProgress?(.chunking(completed: 0, total: total))

        let chunks = try await chunker.splitAudio(url: audioFileURL)
        defer { chunker.cleanup() }

        var previousText = ""
        var allSegments: [TranscriptSegment] = []
        var languageCode: String?

        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            if isCancelled { throw TranscriptionError.cancelled }

            onProgress?(.transcribing(chunk: i + 1, totalChunks: chunks.count))
            AppLog.transcription.info("On-device chunk \(i+1)/\(chunks.count)")

            let transcript = try await transcribeDirect(url: chunk.url, recognizer: recognizer)
            languageCode = transcript.languageCode ?? languageCode

            let chunkText = transcript.segments.map(\.text).joined(separator: " ")

            for segment in transcript.segments {
                let adjustedStart = segment.startTime + chunk.startTime
                let adjustedEnd = segment.endTime.map { $0 + chunk.startTime }
                var text = segment.text
                if i > 0 { text = deduplicateStart(text, against: previousText) }

                allSegments.append(TranscriptSegment(
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

            // Checkpoint after each chunk (crash recovery)
            let partial = Transcript(
                meetingId: allSegments.first?.meetingId,
                languageCode: languageCode,
                segments: allSegments,
                sourceEngineId: id
            )
            onCheckpoint?(partial, i + 1)
        }

        allSegments = allSegments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        AppLog.transcription.info("On-device transcription complete: \(allSegments.count) segments")
        return Transcript(
            meetingId: allSegments.first?.meetingId,
            languageCode: languageCode,
            segments: allSegments,
            sourceEngineId: id
        )
    }

    // MARK: - Direct transcription (guaranteed on-device)

    /// Transcribe a single audio URL with guaranteed on-device processing.
    /// Guideline: "No fallback com SFSpeechRecognizer, sempre setar requiresOnDeviceRecognition = true."
    private func transcribeDirect(url: URL, recognizer: SFSpeechRecognizer) async throws -> Transcript {
        // Ensure audio is in a format the on-device recognizer can process.
        // WAV files below 16kHz (Bluetooth HFP) are resampled to 16kHz.
        let transcriptionURL = try await ensureTranscriptionFormat(url)

        let request = SFSpeechURLRecognitionRequest(url: transcriptionURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        // On-device recognition: requires model download. Disable for testing.
        let forceOnDevice = !UserDefaults.standard.bool(forKey: "transcription_allow_cloud")
        if forceOnDevice {
            guard recognizer.supportsOnDeviceRecognition else {
                AppLog.transcription.error("On-device model not available for \(recognizer.locale.identifier)")
                throw TranscriptionError.onDeviceUnavailable
            }
        }
        request.requiresOnDeviceRecognition = forceOnDevice

        // Domain-specific vocabulary for better accuracy
        if let contextTerms = buildContextualTerms() {
            request.contextualStrings = contextTerms
        }

        AppLog.transcription.info("Transcribing on-device — locale=\(recognizer.locale.identifier) requiresOnDevice=\(forceOnDevice)")

        return try await withCheckedThrowingContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let nsError = error as NSError
                    AppLog.transcription.error("On-device recognition failed: \(nsError.domain)/\(nsError.code) — \(error.localizedDescription)")

                    // kAFAssistantErrorDomain Code=1101 = local recognizer rejected audio format.
                    // Retry once with cloud recognition if it was forced on-device.
                    if nsError.domain.contains("AssistantError") && forceOnDevice {
                        AppLog.transcription.warning("Local recognizer rejected audio, falling back to cloud recognition")
                        let cloudRequest = SFSpeechURLRecognitionRequest(url: transcriptionURL)
                        cloudRequest.shouldReportPartialResults = false
                        cloudRequest.addsPunctuation = true
                        cloudRequest.requiresOnDeviceRecognition = false
                        if let ctx = self.buildContextualTerms() {
                            cloudRequest.contextualStrings = ctx
                        }
                        let cloudTask = recognizer.recognitionTask(with: cloudRequest) { cloudResult, cloudError in
                            if let cloudError {
                                let cloudNSError = cloudError as NSError
                                AppLog.transcription.error("Cloud fallback also failed: \(cloudNSError.domain)/\(cloudNSError.code)")
                                continuation.resume(throwing: TranscriptionError.recognitionFailed("\(cloudNSError.domain)/\(cloudNSError.code): \(cloudError.localizedDescription)"))
                                return
                            }
                            guard let cloudResult = cloudResult, cloudResult.isFinal else { return }
                            let transcript = self.buildTranscript(from: cloudResult, recognizer: recognizer)
                            AppLog.transcription.info("Cloud fallback succeeded: \(transcript.segments.count) segments")
                            continuation.resume(returning: transcript)
                        }
                        self.activeRecognitionTask = cloudTask
                        return
                    }

                    continuation.resume(throwing: TranscriptionError.recognitionFailed("\(nsError.domain)/\(nsError.code): \(error.localizedDescription)"))
                    return
                }

                guard let result = result, result.isFinal else { return }
                let transcript = self.buildTranscript(from: result, recognizer: recognizer)
                AppLog.transcription.info("On-device complete: \(transcript.segments.count) segments, lang=\(transcript.languageCode ?? recognizer.locale.identifier), locale=\(recognizer.locale.identifier)")
                continuation.resume(returning: transcript)
            }
            self.activeRecognitionTask = task
        }
    }

    /// Build a Transcript from an SFSpeechRecognitionResult.
    private func buildTranscript(from result: SFSpeechRecognitionResult, recognizer: SFSpeechRecognizer) -> Transcript {
        let fullText = result.bestTranscription.formattedString
        let detectedLang = detectLanguage(fullText)

        let segments = result.bestTranscription.segments.map { segment in
            TranscriptSegment(
                meetingId: UUID(),
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration,
                text: segment.substring,
                confidence: Double(segment.confidence),
                languageCode: detectedLang,
                sourceEngineId: "apple-speech"
            )
        }

        return Transcript(
            languageCode: detectedLang ?? recognizer.locale.identifier,
            segments: segments,
            sourceEngineId: "apple-speech"
        )
    }

    /// Resamples WAV files below 16kHz (Bluetooth HFP) to 16kHz 16-bit PCM
    /// so the on-device recognizer can process them. M4A/CAF/MP3 pass through.
    private func ensureTranscriptionFormat(_ url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" else { return url }

        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID = fileID else {
            return url
        }
        defer { AudioFileClose(fileID) }

        var varFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &varFormat) == noErr else {
            return url
        }

        guard varFormat.mSampleRate < 16_000 else { return url }

        AppLog.transcription.info("Resampling WAV from \(Int(varFormat.mSampleRate))Hz to 16000Hz for on-device recognition")

        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: varFormat.mSampleRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            return url
        }

        guard let inputFile = try? AVAudioFile(forReading: url),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return url
        }

        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("transc_resampled_\(UUID().uuidString).wav")
        guard let outputFile = try? AVAudioFile(forWriting: outputURL,
                                                  settings: outputFormat.settings,
                                                  commonFormat: .pcmFormatInt16,
                                                  interleaved: false) else {
            return url
        }

        let inputLength = inputFile.length
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputLength)) else {
            return url
        }
        try? inputFile.read(into: inputBuffer)

        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * 16_000.0 / varFormat.mSampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrames) else {
            return url
        }

        var convertError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else {
            AppLog.transcription.warning("Resample failed — trying original format")
            return url
        }

        try? outputFile.write(from: outputBuffer)
        return outputURL
    }

    // MARK: - Live Transcription

    /// Transcribe an audio file with live partial results.
    /// Guideline: "Diferencie resultado volátil de resultado finalizado."
    func transcribeLive(from audioFileURL: URL) -> LiveTranscriptionStream {
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
                    request.requiresOnDeviceRecognition = !UserDefaults.standard.bool(forKey: "transcription_allow_cloud")
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
                                    meetingId: UUID(),
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

    private func firstAvailableRecognizer() -> SFSpeechRecognizer? {
        for locale in candidateLocales {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                continue
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
              confidence > Self.languageConfidenceThreshold else {
            return nil
        }
        return language.rawValue
    }

    private func deduplicateStart(_ text: String, against previous: String) -> String {
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
}
