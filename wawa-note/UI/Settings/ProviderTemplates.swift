import Foundation

enum ProviderCategory: String, CaseIterable {
    case cloud
    case local
}

struct ProviderTemplate: Identifiable, Equatable {
    let id: String
    let displayName: String
    let subtitle: String
    let systemImageName: String
    let providerType: ProviderType
    let baseURL: String
    let defaultModel: String
    let category: ProviderCategory
    let getAPIKeyURL: URL?
    let requiresAuth: Bool
    let scanPort: Int?
    let scanPath: String?

    static func == (lhs: ProviderTemplate, rhs: ProviderTemplate) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Load from config

    static func fromConfig(_ p: AIConfig.ProviderConfig) -> ProviderTemplate {
        let model = p.defaultModel ?? "gpt-5.5"
        let isLocal = p.category == "local"

        return ProviderTemplate(
            id: p.id,
            displayName: p.displayName,
            subtitle: p.description ?? (isLocal ? "Runs on your Mac. Free." : "Cloud AI. Requires an API key."),
            systemImageName: p.iconName,
            providerType: ProviderType(rawValue: p.type) ?? .openAICompatible,
            baseURL: p.baseURL,
            defaultModel: model,
            category: isLocal ? .local : .cloud,
            getAPIKeyURL: p.helpURL.flatMap(URL.init(string:)),
            requiresAuth: p.authType == "api_key",
            scanPort: p.scanPort,
            scanPath: p.scanPath
        )
    }

    // MARK: - Convenience accessors for previews

    private static var byId: [String: ProviderTemplate] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
    static var openAI: ProviderTemplate {
        guard let t = byId["openai"] else { fatalError("OpenAI provider not found in ai_config.json") }
        return t
    }
    static var anthropic: ProviderTemplate {
        guard let t = byId["anthropic"] else { fatalError("Anthropic provider not found in ai_config.json") }
        return t
    }
    static var gemini: ProviderTemplate {
        guard let t = byId["gemini"] else { fatalError("Gemini provider not found in ai_config.json") }
        return t
    }
    static var lmStudio: ProviderTemplate {
        guard let t = byId["lmstudio"] else { fatalError("LM Studio provider not found in ai_config.json") }
        return t
    }
    static var deepseek: ProviderTemplate {
        guard let t = byId["deepseek"] else { fatalError("DeepSeek provider not found in ai_config.json") }
        return t
    }
    static var ollama: ProviderTemplate {
        guard let t = byId["ollama"] else { fatalError("Ollama provider not found in ai_config.json") }
        return t
    }

    // MARK: - Collections (loaded from config)

    static var all: [ProviderTemplate] {
        AIConfigService.shared.allProviders().map(fromConfig)
    }

    static var cloudTemplates: [ProviderTemplate] {
        AIConfigService.shared.cloudProviders().map(fromConfig)
    }

    static var localTemplates: [ProviderTemplate] {
        AIConfigService.shared.localProviders().map(fromConfig)
    }
}
