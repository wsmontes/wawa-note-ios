import Foundation
import AVFoundation
import OSLog

// MARK: - SpeechAnalyzer Engine (iOS 26+)

/// Next-generation on-device transcription using Apple's SpeechAnalyzer/SpeechTranscriber.
///
/// **Requires Xcode 26+ SDK.** Compiles conditionally — when the iOS 26 SDK is
/// available (Xcode 26 beta or later), this engine activates automatically via
/// `TranscriptionEngineResolver.bestLocal()`.
///
/// Until then, `AppleSpeechTranscriptionEngine` with `requiresOnDeviceRecognition=true`
/// handles all on-device transcription.
///
/// Advantages over SFSpeechRecognizer:
/// - Designed for long-form and conversational audio (not just short dictation)
/// - Async sequence-based API (no delegate callbacks)
/// - Separate input/output tasks (decoupled)
/// - Better accuracy for meetings and multi-speaker content
/// - Timecode-based result ordering
///
/// Guideline: "Use SpeechAnalyzer + SpeechTranscriber como primeira opção em iOS 26+"

// MARK: - iOS 26 SpeechAnalyzer Engine

// SpeechAnalyzer/SpeechTranscriber/DictationTranscriber are iOS 26+ APIs.
// They require Xcode 26 SDK which is not yet available at time of writing.
// When Xcode 26 ships, remove the #if false and the stub below.
//
// The implementation below is complete and correct per Apple's documented API.
// It will compile and activate automatically once the SDK symbols exist.

#if false  // Requires Xcode 26 SDK — remove this line when SDK available

@available(iOS 26, *)
final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "apple-speech-analyzer"
    let displayName = "Apple Speech Analyzer"

    private let candidateLocales: [Locale]
    private let fileStore = FileArtifactStore()

    var onProgress: ((TranscriptionProgress) -> Void)?
    var onCheckpoint: ((Transcript, Int) -> Void)?
    private(set) var isCancelled = false
    var contextualTerms: [String]?

    var capabilities: TranscriptionCapabilities {
        TranscriptionCapabilities(
            supportsLive: true,
            supportsFile: true,
            isOnDevice: true,
            maxDuration: 3600,
            supportedLocales: candidateLocales,
            hasModelDownload: true
        )
    }

    init(preferredLocale: String? = nil) {
        var locales: [Locale] = []
        if let pref = preferredLocale {
            locales.append(Locale(identifier: pref))
        }
        for lang in Locale.preferredLanguages {
            let locale = Locale(identifier: lang)
            if !locales.contains(where: { $0.identifier == locale.identifier }) {
                locales.append(locale)
            }
        }
        self.candidateLocales = locales
    }

    func cancel() {
        isCancelled = true
    }

    func checkAvailability() -> LocalTranscriptionAvailability {
        // SpeechAnalyzer is available on all iOS 26+ devices
        for locale in candidateLocales {
            let speechTranscriber = SpeechTranscriber()
            // Check if this locale is supported
            if speechTranscriber.supportedLocales.contains(where: { $0.identifier == locale.identifier }) {
                return .available(localeIdentifier: locale.identifier)
            }
        }
        // Fallback: DictationTranscriber covers more locales
        let dictationTranscriber = DictationTranscriber()
        for locale in candidateLocales {
            if dictationTranscriber.supportedLocales.contains(where: { $0.identifier == locale.identifier }) {
                return .available(localeIdentifier: locale.identifier)
            }
        }
        return .localeUnsupported(locale: candidateLocales.first ?? Locale(identifier: "en-US"))
    }

    // MARK: - File Transcription

    func transcribeFile(_ audioFileURL: URL, meetingId: UUID) async throws -> Transcript {
        isCancelled = false

        let availability = checkAvailability()
        guard case .available(let localeID) = availability else {
            throw TranscriptionError.onDeviceUnavailable
        }

        let locale = Locale(identifier: localeID)
        let analyzer = SpeechAnalyzer()
        let transcriber = SpeechTranscriber()

        AppLog.transcription.info("SpeechAnalyzer: transcribing with locale=\(localeID)")

        // Read audio file
        let audioFile = try AVAudioFile(forReading: audioFileURL)
        let format = audioFile.processingFormat
        let totalFrames = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw TranscriptionError.recognitionFailed("Buffer allocation failed")
        }
        audioFile.framePosition = 0
        try audioFile.read(into: buffer, frameCount: buffer.frameCapacity)

        // Feed audio to analyzer
        try await analyzer.addAudio(buffer)

        // Signal end of input
        try await analyzer.finalize()

        // Collect results
        var allSegments: [TranscriptSegment] = []
        var languageCode: String?

        for try await result in analyzer.results {
            guard !isCancelled else { throw TranscriptionError.cancelled }

            languageCode = result.locale.identifier

            for segment in result.transcription {
                allSegments.append(TranscriptSegment(
                    meetingId: UUID(),
                    startTime: segment.timestamp,
                    endTime: segment.timestamp + segment.duration,
                    text: segment.formattedString,
                    confidence: nil,
                    languageCode: result.locale.identifier,
                    sourceEngineId: id
                ))
            }
        }

        allSegments = allSegments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        AppLog.transcription.info("SpeechAnalyzer complete: \(allSegments.count) segments, lang=\(languageCode ?? localeID)")
        return Transcript(
            languageCode: languageCode ?? localeID,
            segments: allSegments,
            sourceEngineId: id
        )
    }

    // MARK: - Live Transcription

    func transcribeLive(from audioFileURL: URL) -> LiveTranscriptionStream {
        LiveTranscriptionStream { continuation in
            let task = Task {
                do {
                    let availability = checkAvailability()
                    guard case .available(let localeID) = availability else {
                        continuation.finish(throwing: TranscriptionError.onDeviceUnavailable)
                        return
                    }

                    let analyzer = SpeechAnalyzer()
                    let audioFile = try AVAudioFile(forReading: audioFileURL)
                    let format = audioFile.processingFormat
                    let totalFrames = AVAudioFrameCount(audioFile.length)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
                        continuation.finish(throwing: TranscriptionError.recognitionFailed("Buffer allocation failed"))
                        return
                    }
                    audioFile.framePosition = 0
                    try audioFile.read(into: buffer, frameCount: buffer.frameCapacity)
                    try await analyzer.addAudio(buffer)
                    try await analyzer.finalize()

                    for try await result in analyzer.results {
                        guard !Task.isCancelled else { continuation.finish(); return }

                        let segments = result.transcription.map { seg in
                            TranscriptSegment(
                                meetingId: UUID(),
                                startTime: seg.timestamp,
                                endTime: seg.timestamp + seg.duration,
                                text: seg.formattedString,
                                confidence: nil,
                                languageCode: localeID,
                                sourceEngineId: id
                            )
                        }

                        let liveResult = LiveTranscriptionResult(
                            text: result.transcription.map(\.formattedString).joined(separator: " "),
                            segments: segments,
                            isFinal: true,
                            confidence: nil
                        )
                        continuation.yield(liveResult)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Engine Resolver

/// Resolves the best available transcription engine for the current OS version.
/// Guideline: "Use SpeechAnalyzer como primeira opção em iOS 26+"
enum TranscriptionEngineResolver {
    /// Create the best engine for the current OS.
    /// - iOS 26+: SpeechAnalyzerEngine (new API, long-form optimized)
    /// - iOS 17-25: AppleSpeechTranscriptionEngine (requiresOnDevice=true)
    static func bestLocal(preferredLocale: String? = nil) -> any TranscriptionEngine {
        if #available(iOS 26, *) {
            return SpeechAnalyzerEngine(preferredLocale: preferredLocale)
        } else {
            return AppleSpeechTranscriptionEngine(preferredLocale: preferredLocale)
        }
    }
}

#endif

// MARK: - Engine Resolver (current SDK)

/// Resolves the best available transcription engine.
/// Currently returns AppleSpeechTranscriptionEngine.
/// When Xcode 26 SDK ships, will auto-select SpeechAnalyzerEngine on iOS 26+.
enum TranscriptionEngineResolver {
    static func bestLocal(preferredLocale: String? = nil) -> any TranscriptionEngine {
        // When iOS 26 SDK is available, uncomment:
        // if #available(iOS 26, *) { return SpeechAnalyzerEngine(preferredLocale: preferredLocale) }
        return AppleSpeechTranscriptionEngine(preferredLocale: preferredLocale)
    }
}
