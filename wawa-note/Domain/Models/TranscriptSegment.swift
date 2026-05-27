import Foundation

struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    var meetingId: UUID
    var startTime: Double
    var endTime: Double?
    var speakerId: UUID?
    var text: String
    var originalText: String?
    var confidence: Double?
    var languageCode: String?
    var sourceEngineId: String

    init(
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
    let id: UUID
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

struct Transcript: Codable {
    var meetingId: UUID?
    var languageCode: String?
    var segments: [TranscriptSegment]
    var sourceEngineId: String
    var createdAt: Date

    init(
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
    func groupedSegments(pauseThreshold: Double = 0.4, maxChars: Int = 250) -> [TranscriptGroup] {
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
                    groups.append(TranscriptGroup(
                        text: currentTexts.joined(separator: " "),
                        startTime: currentStart,
                        endTime: currentEnd,
                        confidence: currentConfs.isEmpty ? nil : currentConfs.reduce(0, +) / Double(currentConfs.count)
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
            groups.append(TranscriptGroup(
                text: currentTexts.joined(separator: " "),
                startTime: currentStart,
                endTime: currentEnd,
                confidence: currentConfs.isEmpty ? nil : currentConfs.reduce(0, +) / Double(currentConfs.count)
            ))
        }

        return groups
    }
}

/// A subtitle-like block of merged transcript segments.
struct TranscriptGroup: Identifiable {
    let id = UUID()
    let text: String
    let startTime: Double
    let endTime: Double
    let confidence: Double?
}
