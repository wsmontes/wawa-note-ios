import Foundation

// MARK: - Checkpoint

public struct TranscriptionCheckpoint: Codable, Sendable {
  public let completedChunks: Int
  public let segments: [TranscriptSegment]
  public let languageCode: String?
  public let sourceEngineId: String
  public let savedAt: Date
}
