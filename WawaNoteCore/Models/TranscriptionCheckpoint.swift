import Foundation

// MARK: - Checkpoint

struct TranscriptionCheckpoint: Codable, Sendable {
  let completedChunks: Int
  let segments: [TranscriptSegment]
  let languageCode: String?
  let sourceEngineId: String
  let savedAt: Date
}
