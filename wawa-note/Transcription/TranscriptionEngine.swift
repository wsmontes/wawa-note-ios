import Foundation

enum TranscriptionProgress: Sendable {
    case chunking(completed: Int, total: Int)
    case transcribing(chunk: Int, totalChunks: Int)
}

struct TranscriptionCheckpoint: Codable {
    let completedChunks: Int
    let segments: [TranscriptSegment]
    let languageCode: String?
    let sourceEngineId: String
    let savedAt: Date
}

protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isCancelled: Bool { get }

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript
    func cancel()
}
