import Foundation

enum ProviderType: String, Codable, CaseIterable {
    case openAICompatible
    case openAI
    case anthropic
    case gemini
    case localNetwork
    case appleLocal

    /// Human-readable display name suitable for user-facing UI.
    /// Names follow the content guidelines: recognizable brand names
    /// that a non-technical user can understand without prior knowledge.
    var displayName: String {
        switch self {
        case .openAICompatible: "Custom (OpenAI Compatible)"
        case .openAI: "ChatGPT by OpenAI"
        case .anthropic: "Claude by Anthropic"
        case .gemini: "Google Gemini"
        case .localNetwork: "Local Model"
        case .appleLocal: "On-Device (Apple)"
        }
    }

    /// Whether this provider type requires an internet connection.
    /// Local providers work offline; all others need network access.
    var isLocal: Bool {
        switch self {
        case .localNetwork, .appleLocal: true
        default: false
        }
    }

    /// Whether this provider type is a cloud service requiring an API key.
    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .openAICompatible, .anthropic, .gemini: true
        case .localNetwork, .appleLocal: false
        }
    }
}

struct AIProviderConfig: Identifiable, Codable {
    let id: UUID
    var name: String
    var type: ProviderType
    var baseURL: URL?
    var defaultModel: String
    var supportsStreaming: Bool
    var supportsAudio: Bool
    var supportsTools: Bool
    var apiKeyKeychainIdentifier: String?
    var notes: String?

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
        self.type = type
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.supportsStreaming = supportsStreaming
        self.supportsAudio = supportsAudio
        self.supportsTools = supportsTools
        self.apiKeyKeychainIdentifier = apiKeyKeychainIdentifier
        self.notes = notes
    }
}
