import Foundation
import WawaNoteCore

// Related JIRA: KAN-543

enum ProviderEndpointPolicy {
  static func isLocalNetworkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let rawHost = url.host?.lowercased()
    else { return false }

    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }

    let octets = host.split(separator: ".").compactMap { Int($0) }
    if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
      if octets[0] == 10 || octets[0] == 127 { return true }
      if octets[0] == 169 && octets[1] == 254 { return true }
      if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
      if octets[0] == 192 && octets[1] == 168 { return true }
      return false
    }

    guard host.contains(":") else { return false }
    return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
  }
}

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
