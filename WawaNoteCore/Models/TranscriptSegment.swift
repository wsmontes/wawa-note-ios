import Foundation

public struct TranscriptSegment: Identifiable, Codable, Sendable {
  public let id: UUID
  public var meetingId: UUID
  public var startTime: Double
  public var endTime: Double?
  public var speakerId: UUID?
  public var text: String
  public var originalText: String?
  public var confidence: Double?
  public var languageCode: String?
  public var sourceEngineId: String

  public init(
    id: UUID = UUID(),
    meetingId: UUID,
    startTime: Double,
    endTime: Double? = nil,
    speakerId: UUID? = nil,
    text: String,
    originalText: String? = nil,
    confidence: Double? = nil,
    languageCode: String? = nil,
    sourceEngineId: String
  ) {
    self.id = id
    self.meetingId = meetingId
    self.startTime = startTime
    self.endTime = endTime
    self.speakerId = speakerId
    self.text = text
    self.originalText = originalText
    self.confidence = confidence
    self.languageCode = languageCode
    self.sourceEngineId = sourceEngineId
  }
}

struct Speaker: Identifiable, Codable {
  public let id: UUID
  var meetingId: UUID
  var label: String
  var displayName: String?
  var contactIdentifier: String?

  init(
    id: UUID = UUID(),
    meetingId: UUID,
    label: String,
    displayName: String? = nil,
    contactIdentifier: String? = nil
  ) {
    self.id = id
    self.meetingId = meetingId
    self.label = label
    self.displayName = displayName
    self.contactIdentifier = contactIdentifier
  }
}

public struct Transcript: Codable, Sendable {
  public var meetingId: UUID?
  public var languageCode: String?
  public var segments: [TranscriptSegment]
  public var sourceEngineId: String
  public var createdAt: Date

  public init(
    meetingId: UUID? = nil,
    languageCode: String? = nil,
    segments: [TranscriptSegment] = [],
    sourceEngineId: String,
    createdAt: Date = Date()
  ) {
    self.meetingId = meetingId
    self.languageCode = languageCode
    self.segments = segments
    self.sourceEngineId = sourceEngineId
    self.createdAt = createdAt
  }

  /// Groups raw Apple Speech segments into sentence-like subtitle blocks.
  /// A new group starts when the pause between segments exceeds `pauseThreshold`
  /// seconds, or when the group text exceeds `maxChars`.
  public func groupedSegments(pauseThreshold: Double = 0.4, maxChars: Int = 250)
    -> [TranscriptGroup]
  {
    guard !segments.isEmpty else { return [] }

    var groups: [TranscriptGroup] = []
    var currentTexts: [String] = []
    var currentStart = segments[0].startTime
    var currentEnd = segments[0].endTime ?? segments[0].startTime
    var currentConfs: [Double] = []

    for (i, seg) in segments.enumerated() {
      let segEnd = seg.endTime ?? (seg.startTime + 1.0)

      if i > 0 {
        let gap = seg.startTime - currentEnd
        let currentLen = currentTexts.joined(separator: " ").count

        if gap > pauseThreshold || currentLen > maxChars {
          groups.append(
            TranscriptGroup(
              text: currentTexts.joined(separator: " "),
              startTime: currentStart,
              endTime: currentEnd,
              confidence: currentConfs.isEmpty
                ? nil : currentConfs.reduce(0, +) / Double(currentConfs.count)
            ))
          currentTexts = []
          currentStart = seg.startTime
          currentConfs = []
        }
      }

      currentTexts.append(seg.text)
      currentEnd = segEnd
      if let c = seg.confidence { currentConfs.append(c) }
    }

    // Flush last group
    if !currentTexts.isEmpty {
      groups.append(
        TranscriptGroup(
          text: currentTexts.joined(separator: " "),
          startTime: currentStart,
          endTime: currentEnd,
          confidence: currentConfs.isEmpty
            ? nil : currentConfs.reduce(0, +) / Double(currentConfs.count)
        ))
    }

    return groups
  }
}

/// A subtitle-like block of merged transcript segments.
public struct TranscriptGroup: Identifiable {
  public let id = UUID()
  public let text: String
  public let startTime: Double
  public let endTime: Double
  public let confidence: Double?
}
