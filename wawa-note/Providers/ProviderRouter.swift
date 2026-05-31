import Foundation
import SwiftData
import OSLog

final class ProviderRouter: Sendable {
    private let keychain: SecureKeyStore

    init(keychain: SecureKeyStore = SecureKeyStore()) {
        self.keychain = keychain
    }

    static func resolveActive(context: ModelContext) throws -> any AIProvider {
        let manager = ActiveProviderManager.shared
        guard let config = manager.getActiveProvider(context: context) else {
            throw ProviderError.providerNotFound
        }
        return try ProviderRouter().provider(for: config)
    }

    func provider(for config: AIProviderConfigModel) throws -> any AIProvider {
        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidBaseURL
        }
        let apiKey: String
        if config.type.requiresAPIKey {
            guard let keychainId = config.apiKeyKeychainIdentifier else {
                throw ProviderError.missingAPIKey
            }
            do { apiKey = try keychain.loadAPIKey(for: keychainId) }
            catch { throw ProviderError.missingAPIKey }
        } else { apiKey = "" }

        let id = config.id.uuidString

        switch config.type {
        case .anthropic:
            AppLog.provider.info("Provider: \(config.name) (Anthropic Messages API)")
            return AnthropicProvider(
                id: id,
                displayName: config.name,
                baseURL: baseURL,
                apiKey: apiKey,
                model: config.defaultModel
            )

        case .gemini:
            AppLog.provider.info("Provider: \(config.name) (Gemini API)")
            return GeminiProvider(
                id: id,
                displayName: config.name,
                baseURL: baseURL,
                apiKey: apiKey,
                model: config.defaultModel
            )

        case .openAI, .openAICompatible, .localNetwork, .appleLocal:
            AppLog.provider.info("Provider: \(config.name) (OpenAI-compatible API)")
            let capabilities = AIProviderCapabilities(
                supportsStreaming: config.supportsStreaming,
                supportsAudioInput: config.supportsAudio,
                supportsStructuredOutput: config.supportsTools,
                supportsToolCalling: config.supportsTools,
                supportsEmbeddings: config.supportsEmbeddings
            )
            // Resolve endpoint path from provider config (e.g. Ollama uses /v1/chat/completions)
            let endpointPath = AIConfigService.shared.config.providers[config.providerConfigId]?.endpoints?["chat"] ?? "chat/completions"
            return OpenAICompatibleProvider(
                id: id,
                displayName: config.name,
                providerType: config.type,
                baseURL: baseURL,
                apiKey: apiKey,
                model: config.defaultModel,
                capabilities: capabilities,
                endpointPath: endpointPath
            )
        }
    }
}
