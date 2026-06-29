import Foundation

// MARK: - Progress

enum TranscriptionProgress: Sendable {
    case chunking(completed: Int, total: Int)
    case transcribing(chunk: Int, totalChunks: Int)
    case downloadingModel(String)
}

// MARK: - Checkpoint

struct TranscriptionCheckpoint: Codable, Sendable {
    let completedChunks: Int
    let segments: [TranscriptSegment]
    let languageCode: String?
    let sourceEngineId: String
    let savedAt: Date
}

// MARK: - Engine Capabilities

/// Declares what a transcription engine can do.
/// Guideline: "Modele explicitamente os estados. Tenha uma interface comum."
struct TranscriptionCapabilities: Sendable {
    let supportsLive: Bool  // Buffer-based real-time
    let supportsFile: Bool  // URL-based batch
    let isOnDevice: Bool  // Guaranteed local (no network)
    let maxDuration: TimeInterval  // Max audio duration (seconds)
    let supportedLocales: [Locale]
    let hasModelDownload: Bool  // Needs asset download step
}

// MARK: - Live Transcription Types

/// A single live transcription result — can be volatile or final.
struct LiveTranscriptionResult: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    let isFinal: Bool
    let confidence: Double?
}

/// Stream of live transcription results.
typealias LiveTranscriptionStream = AsyncThrowingStream<LiveTranscriptionResult, Error>

// MARK: - Engine Protocol

protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isCancelled: Bool { get }
    var capabilities: TranscriptionCapabilities { get }

    /// Transcribe a pre-recorded audio file.
    /// - Parameter meetingId: the KnowledgeItem ID this transcript belongs to.
    func transcribeFile(_ audioFileURL: URL, meetingId: UUID) async throws -> Transcript

    /// Transcribe a live audio stream (buffer-based).
    /// Returns an async stream of volatile + final results.
    /// Guideline: "Diferencie resultado volátil de resultado finalizado."
    func transcribeLive(from audioFileURL: URL) -> LiveTranscriptionStream

    /// Cancel an in-progress transcription.
    func cancel()

    /// Check engine availability (model, permission, locale).
    func checkAvailability() -> LocalTranscriptionAvailability

    /// Ensure prerequisites are met (model download, permission, etc).
    /// Called before transcription starts.
    func prepareIfNeeded() async throws
}

// MARK: - Default implementations

extension TranscriptionEngine {
    /// Default: not all engines support live transcription.
    func transcribeLive(from audioFileURL: URL) -> LiveTranscriptionStream {
        LiveTranscriptionStream { continuation in
            continuation.finish()
        }
    }

    func prepareIfNeeded() async throws {
        let availability = checkAvailability()
        switch availability {
        case .available:
            return
        case .permissionDenied:
            throw TranscriptionError.notAuthorized
        case .hardwareUnsupported:
            throw TranscriptionError.onDeviceUnavailable
        case .modelMissing(let locale):
            throw TranscriptionError.modelNotInstalled(locale.identifier)
        case .localeUnsupported:
            throw TranscriptionError.noSupportedLocale
        case .failed(let message):
            throw TranscriptionError.recognitionFailed(message)
        }
    }
}
