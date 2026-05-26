import Foundation
import SwiftData

@Model
final class MeetingModel {
    @Attribute(.unique) var id: UUID
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
    var statusRaw: String

    var status: MeetingStatus {
        get { MeetingStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

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
        self.statusRaw = status.rawValue
    }
}

@Model
final class AIProviderConfigModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var typeRaw: String
    var baseURLString: String?
    var defaultModel: String
    var supportsStreaming: Bool
    var supportsAudio: Bool
    var supportsTools: Bool
    var apiKeyKeychainIdentifier: String?
    var notes: String?

    var type: ProviderType {
        get { ProviderType(rawValue: typeRaw) ?? .openAICompatible }
        set { typeRaw = newValue.rawValue }
    }

    var baseURL: URL? {
        get { baseURLString.flatMap(URL.init(string:)) }
        set { baseURLString = newValue?.absoluteString }
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        type: ProviderType = .openAICompatible,
        baseURL: URL? = nil,
        defaultModel: String = "",
        supportsStreaming: Bool = true,
        supportsAudio: Bool = false,
        supportsTools: Bool = false,
        apiKeyKeychainIdentifier: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.baseURLString = baseURL?.absoluteString
        self.defaultModel = defaultModel
        self.supportsStreaming = supportsStreaming
        self.supportsAudio = supportsAudio
        self.supportsTools = supportsTools
        self.apiKeyKeychainIdentifier = apiKeyKeychainIdentifier
        self.notes = notes
    }
}
