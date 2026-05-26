import Foundation

enum MeetingStatus: String, Codable, CaseIterable {
    case draft
    case recording
    case recorded
    case transcribing
    case transcribed
    case analyzing
    case analyzed
    case failed
    case archived
}

struct Meeting: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double?
    var projectId: UUID?
    var audioFileRelativePath: String?
    var transcriptionEngineId: String?
    var analysisProviderId: String?
    var languageCode: String?
    var tags: [String]
    var status: MeetingStatus

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        durationSeconds: Double? = nil,
        projectId: UUID? = nil,
        audioFileRelativePath: String? = nil,
        transcriptionEngineId: String? = nil,
        analysisProviderId: String? = nil,
        languageCode: String? = nil,
        tags: [String] = [],
        status: MeetingStatus = .draft
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durationSeconds = durationSeconds
        self.projectId = projectId
        self.audioFileRelativePath = audioFileRelativePath
        self.transcriptionEngineId = transcriptionEngineId
        self.analysisProviderId = analysisProviderId
        self.languageCode = languageCode
        self.tags = tags
        self.status = status
    }
}
