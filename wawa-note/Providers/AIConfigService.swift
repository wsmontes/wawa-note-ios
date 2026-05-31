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
    let lenses: [String: LensJSON]?


    struct ProviderConfig: Codable, Sendable {
        let id: String; let displayName: String; let type: String
        let baseURL: String; let authType: String
        let helpURL: String?; let iconName: String
        let category: String; let description: String?
        let defaultModel: String?
        let availableModels: [String]?
        let scanPort: Int?; let scanPath: String?
        let endpoints: [String: String]?
    }

    struct DefaultModels: Codable, Sendable {
        let analysis: String?; let chat: String?; let transcription: String?
    }

    struct ModelPreset: Codable, Sendable {
        let contextWindowTokens: Int?
        let maxOutputTokens: Int?
        let supportsTemperature: Bool?
        let supportsMaxTokens: Bool?
        let usesMaxCompletionTokens: Bool?
        let reasoningModel: Bool?
        let deprecated: String?
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

    struct LensJSON: Codable, Sendable {
        let name: String?
        let description: String?
        let icon: String?
        let systemPrompt: String?
        let userPrompt: String?
        let temperature: Double?
        let model: String?
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

    // MARK: - Model capabilities

    func contextWindowTokens(for model: String) -> Int {
        presetFor(model: model)?.contextWindowTokens ?? 128000
    }

    func maxOutputTokens(for model: String) -> Int {
        presetFor(model: model)?.maxOutputTokens ?? 16384
    }

    func isReasoningModel(_ model: String) -> Bool {
        presetFor(model: model)?.reasoningModel ?? false
    }

    func supportsAudioTranscription(for providerType: String) -> Bool {
        guard let pc = config.providers[providerType],
              let endpoints = pc.endpoints else { return false }
        return endpoints["audioTranscription"] != nil
    }

    func availableModels(for providerId: String) -> [String] {
        config.providers[providerId]?.availableModels ?? []
    }

    /// Calculate the maximum characters per chunk for a given model.
    /// Uses ~75% of context window minus output budget, ≈4 chars/token.
    func maxChunkChars(for model: String) -> Int {
        let context = contextWindowTokens(for: model)
        let output = maxOutputTokens(for: model)
        let usableTokens = Int(Double(context) * 0.75) - output
        let safeTokens = max(1000, usableTokens)
        return safeTokens * 4
    }

    // MARK: - Feature parameters (centralized resolution)

    /// Resolved AI request parameters for a feature, adapting to model capabilities.
    /// Call sites should use this instead of hardcoding temperature / maxTokens.
    func requestParams(for feature: String, model: String) -> AIFeatureParams {
        let feat = featureConfig(for: feature)
        let preset = presetFor(model: model)
        let isReasoning = preset?.reasoningModel ?? false

        // Temperature: from feature config, nil for reasoning models
        let temperature: Double? = isReasoning ? nil : (feat?.temperature)

        // Max tokens: feature config ceiling, capped by model preset
        let featMax = feat?.maxCompletionTokens ?? feat?.maxTokens
        let modelMax = preset?.maxOutputTokens ?? 4096
        let maxTokens: Int? = featMax.map { min($0, modelMax) } ?? modelMax

        // Context window for chunking
        let contextWindow = preset?.contextWindowTokens ?? 128000

        return AIFeatureParams(
            temperature: temperature,
            maxTokens: maxTokens,
            contextWindow: contextWindow,
            isReasoning: isReasoning
        )
    }
}

// MARK: - Feature params DTO

struct AIFeatureParams {
    let temperature: Double?
    let maxTokens: Int?
    let contextWindow: Int
    let isReasoning: Bool
}
