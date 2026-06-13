import Foundation
import OSLog

/// Bidirectional bridge between anarlog's `config/anarlog.json` and
/// Wawa Note's `AIConfigService` + `SecureKeyStore`.
///
/// Format (anarlog config.json — simplified):
/// ```json
/// {
///   "version": "1",
///   "providers": {
///     "default": "openai",
///     "openai": { "api_key": "sk-...", "model": "gpt-5.5" },
///     "anthropic": { "api_key": "...", "model": "claude-sonnet-4-6" }
///   },
///   "stt": { "provider": "whisper-local", "model": "tiny" },
///   "language": "en"
/// }
/// ```
///
/// Wawa Note stores provider configs in:
/// - `ai_config.json` for provider definitions and model lists
/// - `SecureKeyStore` (Keychain) for API keys
/// - `UserDefaults` for active provider selection
@MainActor
enum AnarlogConfigBridge {
    private static let logger = Logger(subsystem: "com.wawa.note", category: "AnarlogConfigBridge")

    // MARK: - Import

    /// Read anarlog config from a file and map to Wawa Note settings.
    /// - Returns: Dictionary of provider IDs → API keys, plus the default model preference.
    static func importConfig(from url: URL) throws -> ImportedConfig {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let config = try decoder.decode(AnarlogConfig.self, from: data)

        var apiKeys: [String: String] = [:]
        var defaultProvider: String?
        var models: [String: String] = [:]

        if let defaultId = config.providers?.default {
            defaultProvider = mapProviderId(defaultId)
        }

        for (id, provider) in config.providers?.entries ?? [:] {
            let mappedId = mapProviderId(id)
            if let key = provider.apiKey, !key.isEmpty {
                apiKeys[mappedId] = key
            }
            if let model = provider.model {
                models[mappedId] = model
            }
        }

        logger.info("Imported config: \(apiKeys.count) providers, default=\(defaultProvider ?? "none")")
        return ImportedConfig(apiKeys: apiKeys, defaultProvider: defaultProvider, models: models)
    }

    /// Apply imported config to Wawa Note settings.
    static func apply(_ imported: ImportedConfig) {
        let keyStore = SecureKeyStore()

        for (providerId, apiKey) in imported.apiKeys {
            do {
                try keyStore.saveAPIKey(apiKey, for: providerId)
                logger.info("Stored API key for \(providerId)")
            } catch {
                logger.error("Failed to store API key for \(providerId): \(error)")
            }
        }

        // Apply model preferences
        if let defaultProvider = imported.defaultProvider {
            ActiveProviderManager.shared.setActiveProviderID(defaultProvider)
        }

        for (providerId, model) in imported.models {
            UserDefaults.standard.set(model, forKey: "model_pref_\(providerId)")
        }
    }

    // MARK: - Export

    /// Export Wawa Note config to anarlog format.
    static func exportConfig() throws -> AnarlogConfig {
        let keyStore = SecureKeyStore()
        let activeProviderId = ActiveProviderManager.shared.getActiveProviderID() ?? "openai"

        var entries: [String: AnarlogProviderEntry] = [:]

        for (wawaId, anarlogId) in providerIdMap {
            if let apiKey = try? keyStore.loadAPIKey(for: wawaId) {
                let model = UserDefaults.standard.string(forKey: "model_pref_\(wawaId)")
                entries[anarlogId] = AnarlogProviderEntry(
                    apiKey: apiKey,
                    model: model,
                    baseUrl: nil
                )
            }
        }

        return AnarlogConfig(
            version: "1",
            providers: AnarlogProvidersSection(
                defaultValue: reverseMapProviderId(activeProviderId),
                entries: entries
            ),
            stt: nil,
            language: Locale.current.language.languageCode?.identifier
        )
    }

    /// Write config to a file.
    static func exportConfig(to url: URL) throws {
        let config = try exportConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
        logger.info("Exported config to \(url.path)")
    }

    // MARK: - Provider ID mapping

    /// Wawa Note provider ID → anarlog provider ID
    static let providerIdMap: [(wawa: String, anarlog: String)] = [
        ("openai", "openai"),
        ("anthropic", "anthropic"),
        ("gemini", "google"),
        ("openrouter", "openrouter"),
        ("ollama", "ollama"),
    ]

    static func mapProviderId(_ anarlogId: String) -> String {
        if let match = providerIdMap.first(where: { $0.anarlog == anarlogId }) {
            return match.wawa
        }
        return anarlogId  // Pass through unknown IDs
    }

    static func reverseMapProviderId(_ wawaId: String) -> String {
        if let match = providerIdMap.first(where: { $0.wawa == wawaId }) {
            return match.anarlog
        }
        return wawaId
    }
}

// MARK: - anarlog Config JSON types

struct AnarlogConfig: Codable {
    let version: String
    let providers: AnarlogProvidersSection?
    let stt: AnarlogSTTSection?
    let language: String?
}

struct AnarlogProvidersSection: Codable {
    let `default`: String?
    let entries: [String: AnarlogProviderEntry]?

    enum CodingKeys: String, CodingKey {
        case `default`
        case entries
    }

    init(defaultValue: String?, entries: [String: AnarlogProviderEntry]) {
        self.default = defaultValue
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        self.default = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys(stringValue: "default")!)

        var entries: [String: AnarlogProviderEntry] = [:]
        for key in container.allKeys {
            guard key.stringValue != "default" else { continue }
            if let entry = try? container.decode(AnarlogProviderEntry.self, forKey: key) {
                entries[key.stringValue] = entry
            }
        }
        self.entries = entries.isEmpty ? nil : entries
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKeys.self)
        try container.encodeIfPresent(self.default, forKey: DynamicCodingKeys(stringValue: "default")!)
        if let entries = entries {
            for (key, value) in entries {
                try container.encode(value, forKey: DynamicCodingKeys(stringValue: key)!)
            }
        }
    }
}

struct AnarlogProviderEntry: Codable {
    let apiKey: String?
    let model: String?
    let baseUrl: String?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case baseUrl = "base_url"
    }
}

struct AnarlogSTTSection: Codable {
    let provider: String?
    let model: String?
}

/// Result of importing anarlog config.
struct ImportedConfig {
    let apiKeys: [String: String]      // providerId → apiKey
    let defaultProvider: String?       // providerId
    let models: [String: String]       // providerId → modelName
}

// MARK: - Dynamic coding keys for flexible provider dict

private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
