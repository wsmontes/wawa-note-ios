import Foundation
import Speech
import NaturalLanguage
import OSLog

enum TranscriptionError: Error {
    case notAuthorized
    case recognitionFailed
    case cancelled
    case noSupportedLocale
    case fileTooLarge
    case fileTooLongForLocal(Double)
}

final class AppleSpeechTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "apple-speech"
    let displayName = "Apple Speech"

    static let maxLocalDuration: TimeInterval = 50

    private let candidateLocales: [Locale]
    private let chunker: AudioChunker
    private var activeRecognitionTask: SFSpeechRecognitionTask?

    private static let chunkOverlap: TimeInterval = 1.5

    var onProgress: ((TranscriptionProgress) -> Void)?
    var onCheckpoint: ((Transcript, Int) -> Void)?
    private(set) var isCancelled = false

    init(preferredLocale: String? = nil) {
        var locales: [Locale] = []

        // User-selected locale first (from UI picker)
        if let pref = preferredLocale {
            locales.append(Locale(identifier: pref))
        }

        // Configured locales from ai_config.json
        let cfg = AIConfigService.shared.featureConfig(for: "transcription")
        if let supported = cfg?.supportedLocales {
            for id in supported {
                let locale = Locale(identifier: id)
                if !locales.contains(where: { $0.identifier == locale.identifier }) {
                    locales.append(locale)
                }
            }
        }

        // Device preferred languages as fallback
        for lang in Locale.preferredLanguages {
            let locale = Locale(identifier: lang)
            if !locales.contains(where: { $0.identifier == locale.identifier }) {
                locales.append(locale)
            }
        }

        self.candidateLocales = locales
        self.chunker = AudioChunker(chunkDuration: Self.maxLocalDuration, overlap: Self.chunkOverlap)
        AppLog.transcription.info("Transcription locales (priority): \(locales.map(\.identifier).prefix(5).joined(separator: ", "))")
    }

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

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript {
        isCancelled = false

        guard firstAvailableRecognizer() != nil else {
            AppLog.transcription.error("No supported speech recognizer locale available — language pack may not be downloaded")
            throw TranscriptionError.noSupportedLocale
        }

        let status = await requestAuthorization()
        guard status == .authorized else {
            AppLog.transcription.error("Speech recognition not authorized")
            throw TranscriptionError.notAuthorized
        }

        let duration = getDuration(audioFileURL)

        if duration <= Self.maxLocalDuration {
            return try await transcribeDirect(url: audioFileURL)
        }

        AppLog.transcription.info("File duration \(String(format: "%.0f", duration))s exceeds local limit, chunking...")
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
            AppLog.transcription.info("Local chunk \(i+1)/\(chunks.count)")

            let transcript = try await transcribeDirect(url: chunk.url)
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

            // Checkpoint after each chunk
            let partial = Transcript(
                meetingId: allSegments.first?.meetingId,
                languageCode: languageCode,
                segments: allSegments,
                sourceEngineId: id
            )
            onCheckpoint?(partial, i + 1)
        }

        allSegments = allSegments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        AppLog.transcription.info("Local chunked transcription complete: \(allSegments.count) segments")
        return Transcript(
            meetingId: allSegments.first?.meetingId,
            languageCode: languageCode,
            segments: allSegments,
            sourceEngineId: id
        )
    }

    // MARK: - Direct transcription

    private func transcribeDirect(url: URL) async throws -> Transcript {
        guard let recognizer = firstAvailableRecognizer() else {
            AppLog.transcription.error("No supported speech recognizer locale available")
            throw TranscriptionError.noSupportedLocale
        }

        AppLog.transcription.info("Transcribing with locale: \(recognizer.locale.identifier)")

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // SFSpeechRecognizer handles language from its locale. Audio auto-detection
        // can override this — if Portuguese is being transcribed as English, the
        // pt-BR recognizer locale may not be available yet (language pack download
        // happens on first use; ensure device has internet).

        return try await withCheckedThrowingContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    AppLog.transcription.error("Recognition error: \(error.localizedDescription)")
                    continuation.resume(throwing: TranscriptionError.recognitionFailed)
                    return
                }

                guard let result = result, result.isFinal else { return }

                let fullText = result.bestTranscription.formattedString
                let detectedLang = self.detectLanguage(fullText)

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

                let transcript = Transcript(
                    languageCode: detectedLang ?? recognizer.locale.identifier,
                    segments: segments,
                    sourceEngineId: "apple-speech"
                )

                AppLog.transcription.info("Transcription complete: \(segments.count) segments, language: \(detectedLang ?? "unknown")")
                continuation.resume(returning: transcript)
            }
            self.activeRecognitionTask = task
        }
    }

    // MARK: - Private

    private func getDuration(_ url: URL) -> Float64 {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return 0 }
        defer { AudioFileClose(fileID) }
        var duration: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &size, &duration)
        return duration
    }

    private func firstAvailableRecognizer() -> SFSpeechRecognizer? {
        for locale in candidateLocales {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                continue
            }
            return recognizer
        }
        return nil
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
