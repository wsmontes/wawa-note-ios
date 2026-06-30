import Foundation
import OSLog
import SwiftData

// Related JIRA: KAN-9, KAN-42

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

    // MARK: - Offline-aware provider resolution

    /// Resolves the best available provider considering connectivity.
    /// If offline, prefers local providers; if online, uses the active provider.
    func resolveBestAvailable(context: ModelContext) throws -> (any AIProvider, AIProviderConfigModel) {
        let isOnline = NetworkMonitor.shared.isAvailable

        if !isOnline {
            // Offline: find a local provider
            let allConfigs = (try? context.fetch(FetchDescriptor<AIProviderConfigModel>())) ?? []
            if let localConfig = allConfigs.first(where: { $0.type.isLocal }) {
                AppLog.provider.info("Offline — using local provider: \(localConfig.name)")
                let provider = try provider(for: localConfig)
                return (provider, localConfig)
            }
            // No local provider available — fail fast
            throw ProviderError.networkUnavailable
        }

        // Online: use the active provider
        let manager = ActiveProviderManager.shared
        guard let config = manager.getActiveProvider(context: context) else {
            throw ProviderError.providerNotFound
        }
        let provider = try provider(for: config)
        return (provider, config)
    }

    /// Offline fallback policy: ordered list of provider types to try.
    /// When the primary fails, try the next one in the chain.
    func resolveWithFallback(context: ModelContext, preferredTypes: [ProviderType] = [.openAICompatible, .local]) throws -> any AIProvider {
        let allConfigs = (try? context.fetch(FetchDescriptor<AIProviderConfigModel>())) ?? []

        for type in preferredTypes {
            if let config = allConfigs.first(where: { $0.type.normalizedForRouting == type.normalizedForRouting }) {
                do {
                    return try provider(for: config)
                } catch {
                    AppLog.provider.warning("Provider \(config.name) failed: \(error.localizedDescription) — trying next")
                    continue
                }
            }
        }
        throw ProviderError.providerNotFound
    }

    // MARK: - Provider factory

    func provider(for config: AIProviderConfigModel) throws -> any AIProvider {
        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidBaseURL
        }
        let apiKey: String
        if config.type.requiresAPIKey {
            guard let keychainId = config.apiKeyKeychainIdentifier else {
                throw ProviderError.missingAPIKey
            }
            do { apiKey = try keychain.loadAPIKey(for: keychainId) } catch { throw ProviderError.missingAPIKey }
        } else {
            apiKey = ""
        }

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

        case .openAI, .openAICompatible, .localNetwork, .appleLocal, .local:
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
            // Detect OpenRouter for special handling (pricing, provider routing)
            if baseURL.absoluteString.contains("openrouter.ai") {
                AppLog.provider.info("Provider: \(config.name) (OpenRouter — multi-provider gateway)")
            }
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
