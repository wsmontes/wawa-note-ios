import Foundation

enum ProviderType: String, Codable, CaseIterable {
  case openAICompatible
  case openAI
  case anthropic
  case gemini
  case localNetwork  // legacy — mapped to .local in routing
  case appleLocal  // legacy — mapped to .local in routing
  case local  // unified local type (replaces localNetwork + appleLocal)

  /// Human-readable display name suitable for user-facing UI.
  var displayName: String {
    switch self {
    case .openAICompatible: "Custom (OpenAI Compatible)"
    case .openAI: "ChatGPT by OpenAI"
    case .anthropic: "Claude by Anthropic"
    case .gemini: "Google Gemini"
    case .local: "Local Model"
    case .localNetwork: "Local Model"
    case .appleLocal: "On-Device (Apple)"
    }
  }

  /// Whether this provider type requires an internet connection.
  var isLocal: Bool {
    switch self {
    case .localNetwork, .appleLocal, .local: true
    default: false
    }
  }

  /// Whether this provider type is a cloud service requiring an API key.
  var requiresAPIKey: Bool {
    switch self {
    case .openAI, .openAICompatible, .anthropic, .gemini: true
    case .localNetwork, .appleLocal, .local: false
    }
  }

  /// Normalized type for routing — legacy local types map to unified `.local`.
  var normalizedForRouting: Self {
    switch self {
    case .localNetwork, .appleLocal: .local
    default: self
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
  var supportsEmbeddings: Bool
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
    supportsEmbeddings: Bool = false,
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
    self.supportsEmbeddings = supportsEmbeddings
    self.apiKeyKeychainIdentifier = apiKeyKeychainIdentifier
    self.notes = notes
  }
}
