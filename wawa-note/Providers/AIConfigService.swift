import Foundation
import OSLog

// MARK: - Config models

struct AIConfig: Codable, Sendable {
    let version: String
    let description: String?
    let providers: [String: ProviderConfig]
    let defaultModels: DefaultModels?
    let modelPresets: [String: ModelPreset]?
    let features: [String: FeatureConfig]?

    struct ProviderConfig: Codable, Sendable {
        let id: String; let displayName: String; let type: String
        let baseURL: String; let authType: String
        let helpURL: String?; let iconName: String
        let category: String; let description: String?
        let defaultModel: String?
        let scanPort: Int?; let scanPath: String?
        let endpoints: [String: String]?
    }

    struct DefaultModels: Codable, Sendable {
        let analysis: String?; let chat: String?; let transcription: String?
    }

    struct ModelPreset: Codable, Sendable {
        let supportsTemperature: Bool?
        let supportsMaxTokens: Bool?
        let usesMaxCompletionTokens: Bool?
    }

    struct FeatureConfig: Codable, Sendable {
        let provider: String?; let model: String?
        let engine: String?; let fallbackEngine: String?
        let temperature: Double?
        let maxCompletionTokens: Int?
        let maxTokens: Int?
        let systemPrompt: String?; let userPrompt: String?
        let supportedLocales: [String]?
    }
}

// MARK: - Service

final class AIConfigService: @unchecked Sendable {
    static let shared = AIConfigService()

    let config: AIConfig

    private init() {
        guard let url = Bundle.main.url(forResource: "ai_config", withExtension: "json") else {
            AppLog.provider.error("ai_config.json not found in bundle")
            fatalError("ai_config.json is required")
        }
        do {
            let data = try Data(contentsOf: url)
            config = try JSONDecoder().decode(AIConfig.self, from: data)
            AppLog.provider.info("Loaded AI config v\(self.config.version): \(self.config.providers.count) providers, \(self.config.features?.count ?? 0) features")
        } catch {
            AppLog.provider.error("Failed to decode ai_config.json: \(error)")
            fatalError("ai_config.json is invalid: \(error)")
        }
    }

    // MARK: - Providers

    func providerConfig(for id: String) -> AIConfig.ProviderConfig? {
        config.providers[id]
    }

    func allProviders() -> [AIConfig.ProviderConfig] {
        Array(config.providers.values)
    }

    func cloudProviders() -> [AIConfig.ProviderConfig] {
        config.providers.values.filter { $0.category == "cloud" }
    }

    func localProviders() -> [AIConfig.ProviderConfig] {
        config.providers.values.filter { $0.category == "local" }
    }

    // MARK: - Features

    func featureConfig(for feature: String) -> AIConfig.FeatureConfig? {
        config.features?[feature]
    }

    func modelFor(feature: String) -> String {
        if let m = config.features?[feature]?.model { return m }
        if feature == "analysis" { return config.defaultModels?.analysis ?? "gpt-5.5" }
        if feature == "chat" { return config.defaultModels?.chat ?? "gpt-5.5" }
        if feature == "transcription" { return config.defaultModels?.transcription ?? "whisper-1" }
        return "gpt-5.5"
    }

    func presetFor(model: String) -> AIConfig.ModelPreset? {
        config.modelPresets?[model]
    }

    func systemPrompt(for feature: String) -> String? {
        config.features?[feature]?.systemPrompt
    }

    func userPrompt(for feature: String) -> String? {
        config.features?[feature]?.userPrompt
    }

    // MARK: - Prompt rendering

    func renderPrompt(for feature: String, variables: [String: String]) -> String {
        guard var template = userPrompt(for: feature) else { return "" }
        for (key, value) in variables {
            template = template.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return template
    }
}
