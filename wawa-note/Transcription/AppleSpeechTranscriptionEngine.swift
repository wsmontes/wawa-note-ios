import Foundation
import Speech
import OSLog

enum TranscriptionError: Error {
    case notAuthorized
    case recognitionFailed
    case cancelled
}

final class AppleSpeechTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "apple-speech"
    let displayName = "Apple Speech"

    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript {
        let status = await requestAuthorization()
        guard status == .authorized else {
            AppLog.transcription.error("Speech recognition not authorized: \(status.rawValue)")
            throw TranscriptionError.notAuthorized
        }

        guard let recognizer = recognizer, recognizer.isAvailable else {
            AppLog.transcription.error("Speech recognizer unavailable")
            throw TranscriptionError.recognitionFailed
        }

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        AppLog.transcription.info("Starting transcription for: \(audioFileURL.lastPathComponent)")

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    AppLog.transcription.error("Recognition error: \(error.localizedDescription)")
                    continuation.resume(throwing: TranscriptionError.recognitionFailed)
                    return
                }

                guard let result = result, result.isFinal else { return }

                let segments = result.bestTranscription.segments.map { segment in
                    TranscriptSegment(
                        meetingId: UUID(),
                        startTime: segment.timestamp,
                        endTime: segment.timestamp + segment.duration,
                        text: segment.substring,
                        confidence: Double(segment.confidence),
                        sourceEngineId: "apple-speech"
                    )
                }

                let transcript = Transcript(
                    languageCode: recognizer.locale.identifier,
                    segments: segments,
                    sourceEngineId: "apple-speech"
                )

                AppLog.transcription.info("Transcription complete: \(segments.count) segments")
                continuation.resume(returning: transcript)
            }
        }
    }
}
