import Foundation
import SwiftData

@Model
final class AIProviderConfigModel {
  @Attribute(.unique) var id: UUID
  var name: String
  var typeRaw: String
  var providerConfigId: String
  var baseURLString: String?
  var defaultModel: String
  var supportsStreaming: Bool
  var supportsAudio: Bool
  var supportsTools: Bool
  var supportsEmbeddings: Bool
  var availableModelsJSON: String?
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

  var availableModels: [String] {
    get {
      guard let json = availableModelsJSON,
        let data = json.data(using: .utf8),
        let arr = try? JSONDecoder().decode([String].self, from: data)
      else { return [] }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        availableModelsJSON = String(data: data, encoding: .utf8)
      }
    }
  }

  init(
    id: UUID = UUID(),
    name: String = "",
    type: ProviderType = .openAICompatible,
    providerConfigId: String = "",
    baseURL: URL? = nil,
    defaultModel: String = "",
    supportsStreaming: Bool = true,
    supportsAudio: Bool = false,
    supportsTools: Bool = false,
    supportsEmbeddings: Bool = false,
    availableModels: [String] = [],
    apiKeyKeychainIdentifier: String? = nil,
    notes: String? = nil
  ) {
    self.id = id
    self.name = name
    self.typeRaw = type.rawValue
    self.providerConfigId = providerConfigId
    self.baseURLString = baseURL?.absoluteString
    self.defaultModel = defaultModel
    self.supportsStreaming = supportsStreaming
    self.supportsAudio = supportsAudio
    self.supportsTools = supportsTools
    self.supportsEmbeddings = supportsEmbeddings
    if let data = try? JSONEncoder().encode(availableModels),
      let json = String(data: data, encoding: .utf8)
    {
      self.availableModelsJSON = availableModels.isEmpty ? nil : json
    }
    self.apiKeyKeychainIdentifier = apiKeyKeychainIdentifier
    self.notes = notes
  }

  // MARK: - Validation

  /// Validate the model's integrity. Returns array of validation errors (empty = valid).
  /// Checks: name not empty, type is valid, baseURL is parseable, availableModelsJSON is valid.
  func validate() -> [String] {
    var errors: [String] = []

    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errors.append("Provider name is empty")
    }

    if ProviderType(rawValue: typeRaw) == nil {
      errors.append("Unknown provider type: '\(typeRaw)'")
    }

    if let urlStr = baseURLString, !urlStr.isEmpty, URL(string: urlStr) == nil {
      errors.append("Invalid baseURL: '\(urlStr)'")
    }

    // Validate availableModelsJSON parses correctly
    if let json = availableModelsJSON, !json.isEmpty {
      if let data = json.data(using: .utf8),
        (try? JSONDecoder().decode([String].self, from: data)) == nil
      {
        errors.append("availableModelsJSON is corrupted (not a valid JSON string array)")
      }
    }

    return errors
  }

  /// Check if the API key exists in the Keychain for this provider.
  func isAPIKeyPresent() -> Bool {
    guard let identifier = apiKeyKeychainIdentifier else { return false }
    return (try? SecureKeyStore().loadAPIKey(for: identifier)) != nil
  }
}
