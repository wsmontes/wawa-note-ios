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
}
