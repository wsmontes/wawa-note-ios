import AudioToolbox
import Foundation

// Related JIRA: KAN-6

// MARK: - Progress

enum TranscriptionProgress: Sendable {
    case chunking(completed: Int, total: Int)
    case transcribing(chunk: Int, totalChunks: Int)
    case downloadingModel(String)
}

// MARK: - Checkpoint

/// Generic checkpoint for persisting partial transcription results.
/// Used by FileArtifactStore for crash recovery.
/// NOTE: AppleSpeechTranscriptionEngine has its own nested TranscriptionCheckpoint
/// with a different shape (lastChunkIndex/totalChunks). The two serve different
/// purposes and should eventually be unified into one canonical type.
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

/// Protocol abstracting speech-to-text transcription engines.
///
/// Supports both live (buffer-based) and file-based (batch) transcription.
/// Engines declare their capabilities upfront so the dispatch logic in
/// `ContentExtractionService` can route to the best available engine.
///
/// ## Implementations
/// - `AppleSpeechTranscriptionEngine` — on-device SFSpeechRecognizer (supports live + file)
/// - `RemoteTranscriptionEngine` — cloud Whisper API (file only)
///
/// ## Related Docs
/// - `docs/CONTENT_PIPELINE.md` — where transcription fits in the pipeline
/// - `docs/AUDIO_CAPTURE_ENGINE.md` — audio capture before transcription
protocol TranscriptionEngine: Sendable {
    /// Unique identifier for this engine instance.
    var id: String { get }
    /// Human-readable name shown in settings.
    var displayName: String { get }
    /// Whether a cancellation has been requested.
    var isCancelled: Bool { get }
    /// What this engine can do (live, file, on-device, locales, model download).
    var capabilities: TranscriptionCapabilities { get }

    /// Transcribe a pre-recorded audio file.
    /// - Parameter audioFileURL: Path to the audio file (PCM WAV or M4A).
    /// - Parameter meetingId: The KnowledgeItem ID this transcript belongs to.
    /// - Returns: A `Transcript` with segments, language, and confidence scores.
    func transcribeFile(_ audioFileURL: URL, meetingId: UUID) async throws -> Transcript

    /// Transcribe a live audio stream (buffer-based).
    /// Returns an async stream of volatile + final results.
    /// Volatile results update in real-time; final results are immutable.
    /// - Parameter meetingId: The KnowledgeItem ID these segments belong to.
    func transcribeLive(from audioFileURL: URL, meetingId: UUID) -> LiveTranscriptionStream

    /// Cancel an in-progress transcription.
    func cancel()

    /// Check engine availability (model downloaded, permission granted, locale supported).
    /// - Returns: Availability status with reason if unavailable.
    func checkAvailability() -> LocalTranscriptionAvailability

    /// Ensure prerequisites are met (model download, permission, etc).
    /// Called before transcription starts.
    func prepareIfNeeded() async throws
}

// MARK: - Default implementations

extension TranscriptionEngine {
    /// Default: not all engines support live transcription.
    func transcribeLive(from audioFileURL: URL, meetingId: UUID) -> LiveTranscriptionStream {
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

// MARK: - Shared Transcription Utilities

/// Returns the estimated duration of an audio file in seconds.
/// Uses AudioFileGetProperty for O(1) access without decoding.
func transcriptionGetDuration(_ url: URL) -> Float64 {
    var fileID: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return 0 }
    defer { AudioFileClose(fileID) }
    var duration: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &size, &duration)
    return duration
}

/// Removes word overlap between consecutive transcription chunks.
/// Used by RemoteTranscriptionEngine (fixed-duration chunking with overlap).
func transcriptionDeduplicateStart(_ text: String, against previous: String) -> String {
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
