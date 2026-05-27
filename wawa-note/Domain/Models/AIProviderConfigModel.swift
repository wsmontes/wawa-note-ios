import Foundation
import SwiftData

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
