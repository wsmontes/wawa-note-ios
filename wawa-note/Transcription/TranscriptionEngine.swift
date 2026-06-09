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
    let supportsLive: Bool           // Buffer-based real-time
    let supportsFile: Bool           // URL-based batch
    let isOnDevice: Bool             // Guaranteed local (no network)
    let maxDuration: TimeInterval    // Max audio duration (seconds)
    let supportedLocales: [Locale]
    let hasModelDownload: Bool       // Needs asset download step
}

// MARK: - Engine Protocol

protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isCancelled: Bool { get }
    var capabilities: TranscriptionCapabilities { get }

    /// Transcribe a pre-recorded audio file.
    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript

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
    func prepareIfNeeded() async throws {
        let availability = checkAvailability()
        switch availability {
        case .available:
            return // Ready
        case .permissionDenied:
            throw TranscriptionError.notAuthorized
        case .hardwareUnsupported:
            throw TranscriptionError.onDeviceUnavailable
        case .modelMissing(let locale):
            throw TranscriptionError.modelNotInstalled(locale.identifier)
        case .localeUnsupported(let locale):
            throw TranscriptionError.noSupportedLocale
        case .failed(let message):
            throw TranscriptionError.recognitionFailed(message)
        }
    }
}
