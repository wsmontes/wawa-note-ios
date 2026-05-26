import Foundation
import OSLog

final class ProviderRouter: Sendable {
    private let keychain: SecureKeyStore

    init(keychain: SecureKeyStore = SecureKeyStore()) {
        self.keychain = keychain
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
            do {
                apiKey = try keychain.loadAPIKey(for: keychainId)
            } catch {
                throw ProviderError.missingAPIKey
            }
        } else {
            apiKey = ""
        }

        let capabilities = AIProviderCapabilities(
            supportsStreaming: config.supportsStreaming,
            supportsAudioInput: config.supportsAudio,
            supportsStructuredOutput: config.supportsTools,
            supportsToolCalling: config.supportsTools,
            supportsEmbeddings: false
        )

        AppLog.provider.info("Router created provider: \(config.name) (\(config.type.displayName))")

        return OpenAICompatibleProvider(
            id: config.id.uuidString,
            displayName: config.name,
            baseURL: baseURL,
            apiKey: apiKey,
            model: config.defaultModel,
            capabilities: capabilities
        )
    }
}
