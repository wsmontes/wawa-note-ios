import Foundation
import OSLog
import SwiftData

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
        /// Explicitly disable thinking/reasoning mode (DeepSeek, Qwen, etc.).
        /// Sends `{"thinking": {"type": "disabled"}}` in the request body.
        let explicitlyDisableThinking: Bool?
        /// Whether this model supports `response_format: json_object`.
        /// Defaults to !reasoningModel if not set.
        let supportsJSONFormat: Bool?
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
        if let url = Bundle.main.url(forResource: "ai_config", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                config = try JSONDecoder().decode(AIConfig.self, from: data)
                AppLog.provider.info("Loaded AI config v\(self.config.version): \(self.config.providers.count) providers, \(self.config.features?.count ?? 0) features")
                validateConfig()
                return
            } catch let decodingError as DecodingError {
                let detail = Self.describeDecodingError(decodingError)
                AppLog.provider.error("ai_config.json decode failed: \(detail) — using default config")
            } catch {
                AppLog.provider.error("Failed to load ai_config.json: \(error) — using default config")
            }
        } else {
            AppLog.provider.error("ai_config.json not found in bundle — using default config")
        }
        // Fallback: empty config with sensible defaults — app launches without ai_config.json
        config = AIConfig(
            version: "1.0",
            description: "Default config (failed to load)",
            providers: [:],
            defaultModels: nil,
            modelPresets: [:],
            features: [:],
            lenses: nil
        )
    }

    /// Validate loaded config and warn about critical issues.
    private func validateConfig() {
        var warnings: [String] = []

        if config.providers.isEmpty {
            warnings.append("No providers defined — provider templates will be empty")
        }
        for (id, p) in config.providers {
            if p.displayName.isEmpty { warnings.append("Provider '\(id)' has empty displayName") }
            if p.availableModels?.isEmpty ?? true { warnings.append("Provider '\(id)' has no availableModels listed") }
            if p.defaultModel?.isEmpty ?? true { warnings.append("Provider '\(id)' has no defaultModel") }
        }

        if let features = config.features {
            if features["analysis"] == nil { warnings.append("No 'analysis' feature config defined") }
            if features["chat"] == nil { warnings.append("No 'chat' feature config defined") }
        } else {
            warnings.append("No features defined — analysis/chat will use hardcoded defaults")
        }

        for w in warnings {
            AppLog.provider.warning("ai_config.json: \(w)")
        }

        if !warnings.isEmpty {
            AppLog.event("config", "ai_config.json loaded with \(warnings.count) warning(s)")
        }
    }

    /// Human-readable description of a DecodingError for debugging.
    private static func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "/"))"
        case .typeMismatch(let type, let ctx):
            return "type mismatch: expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "/"))"
        case .valueNotFound(let type, let ctx):
            return "nil value for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "/"))"
        case .dataCorrupted(let ctx):
            return "corrupted data at \(ctx.codingPath.map(\.stringValue).joined(separator: "/")): \(ctx.debugDescription)"
        @unknown default:
            return "unknown decode error: \(error.localizedDescription)"
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
        // Config-provided presets are the source of truth.
        if let explicit = presetFor(model: model)?.reasoningModel { return explicit }
        // Heuristic fallback: detect new/unknown reasoning models by name pattern.
        // This prevents silent failures when users configure models that don't
        // have presets yet (e.g., newly released o-series, Claude 5, etc.).
        // Reasoning models MUST NOT receive temperature — sending it causes
        // API errors on most providers.
        //
        // Strategy: prefix/family patterns for known model series + a broad
        // "-thinking"/"reasoner" catch-all. False positives (treating a non-reasoning
        // model as reasoning → temperature=nil) are far less harmful than false
        // negatives (sending temperature to a reasoning model → API error).
        let lower = model.lowercased()
        // Model family prefixes: o1, o3, o4, ... match "o1-mini", "o3-pro", etc.
        // r1 matches "deepseek-r1", "r1-distill", etc.
        // qwq matches "qwq-32b", "qwq-v2", etc.
        let reasoningPrefixes = ["o1", "o3", "o4", "o5", "o6", "o7", "o8", "o9",
                                 "r1", "qwq"]
        for prefix in reasoningPrefixes {
            // Match at word boundary: starts with prefix, or has "/<prefix>" or "-<prefix>"
            if lower.hasPrefix(prefix) { return true }
            if lower.contains("/\(prefix)") || lower.contains("-\(prefix)") { return true }
        }
        // Broad catch-all: models with "-thinking", "-reasoner", "reasoning" in ID
        let broadPatterns = ["-thinking", "-reasoner", "reasoning"]
        return broadPatterns.contains(where: { lower.contains($0) })
    }

    /// Whether to explicitly disable thinking mode (DeepSeek, Qwen, etc.).
    func shouldDisableThinking(for model: String) -> Bool {
        presetFor(model: model)?.explicitlyDisableThinking ?? false
    }

    /// Whether this model supports JSON format (response_format: json_object).
    /// Defaults to !reasoningModel if not explicitly set.
    func supportsJSONFormat(for model: String) -> Bool {
        if let explicit = presetFor(model: model)?.supportsJSONFormat { return explicit }
        return !isReasoningModel(model)
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

        // Rate limiting: monitor burst calls (non-blocking, just logs)
        let minInterval: TimeInterval = feature == "chat" ? 0.5 : 2.0
        if let elapsed = Self.timeSinceLastCall(feature: feature, model: model), elapsed < minInterval {
            AppLog.provider.info("Rate limit: \(feature) called \(String(format: "%.1f", elapsed))s after last")
        }
        Self.recordCall(feature: feature, model: model)

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

    private static let usageLock = NSLock()
    private static nonisolated(unsafe) var _lastCallTimes: [String: TimeInterval] = [:]
    private static nonisolated(unsafe) var _totalTokens: Int = 0
    private static nonisolated(unsafe) var _totalCalls: Int = 0

    /// Thread-safe last call time for a feature+model pair.
    static func recordCall(feature: String, model: String) {
        usageLock.withLock { _lastCallTimes["\(feature):\(model)"] = Date().timeIntervalSince1970 }
    }

    /// Thread-safe elapsed time since last call (nil if never called).
    static func timeSinceLastCall(feature: String, model: String) -> TimeInterval? {
        usageLock.withLock {
            guard let last = _lastCallTimes["\(feature):\(model)"] else { return nil }
            return Date().timeIntervalSince1970 - last
        }
    }

    /// Track API usage for cost estimation.
    static func trackUsage(tokens: Int) {
        usageLock.withLock {
            _totalTokens += tokens
            _totalCalls += 1
        }
    }

    /// Estimated cost in USD for all API calls this session (thread-safe snapshot).
    static var estimatedCost: String {
        let (tokens, calls) = usageLock.withLock { (_totalTokens, _totalCalls) }
        let costPer1K = 0.002
        let cost = Double(tokens) / 1000.0 * costPer1K
        return String(format: "$%.4f (%d calls, %d tokens)", cost, calls, tokens)
    }

    /// Quick health check: pings each configured provider endpoint.
    static func healthCheck(context: ModelContext) async -> [(String, Bool)] {
        let configs = (try? context.fetch(FetchDescriptor<AIProviderConfigModel>())) ?? []
        var results: [(String, Bool)] = []
        for config in configs {
            guard let base = config.baseURLString, let url = URL(string: base) else { continue }
            var req = URLRequest(url: url.appendingPathComponent("health"))
            req.httpMethod = "HEAD"
            req.timeoutInterval = 5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                results.append((config.name, true))
            } else {
                results.append((config.name, false))
            }
        }
        return results
    }
}

// MARK: - Feature params DTO

struct AIFeatureParams {
    let temperature: Double?
    let maxTokens: Int?
    let contextWindow: Int
    let isReasoning: Bool
}
