import Foundation
// Related JIRA: KAN-9, KAN-42


// MARK: - JSON-Driven Model Policy Rules

struct ModelPolicyRules: Codable, Sendable {
    var budget: BudgetRules
    var tiers: [String: TierConfig]
    var features: [String: [String: String]]
    var offlineFallback: OfflineFallbackConfig
    var userOverride: UserOverrideConfig

    struct BudgetRules: Codable, Sendable {
        var dailyUSD: Double
        var thresholds: [BudgetThreshold]
    }

    struct BudgetThreshold: Codable, Sendable {
        var minPercent: Double
        var tier: String
    }

    struct TierConfig: Codable, Sendable {
        var label: String?
        var prefer: [String]
    }

    struct OfflineFallbackConfig: Codable, Sendable {
        var enabled: Bool
        var timeoutSeconds: Double?
    }

    struct UserOverrideConfig: Codable, Sendable {
        var enabled: Bool
    }
}

extension ModelPolicyRules {
    func tier(for budgetPercent: Double) -> String {
        let sorted = budget.thresholds.sorted(by: { $0.minPercent > $1.minPercent })
        for threshold in sorted {
            if budgetPercent >= threshold.minPercent {
                return threshold.tier
            }
        }
        return sorted.last?.tier ?? "economy"
    }

    func model(for feature: String, tier: String) -> String? {
        features[feature]?[tier]
            ?? features["chat"]?[tier]
            ?? tiers[tier]?.prefer.first
    }
}

// MARK: - ModelPolicy Protocol

protocol ModelPolicy: Sendable {
    func selectModel(
        for feature: String,
        budget: BudgetState,
        userTier: String?,
        override: ModelOverride?
    ) async -> ModelSelection

    func availableModels() async -> [String]
}

// MARK: - Config Types (populated by JSON config parsing)

struct ProviderTemplateConfig: Codable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var icon: String
    var type: ProviderType
    var baseURL: String
    var auth: AuthMethod
    var authHeader: String?
    var authPrefix: String?
    var defaultModels: [String]
    var autoDiscover: Bool
    var discoveryPort: Int?
    var description: String
    var requiresAuth: Bool

    enum AuthMethod: String, Codable, Sendable {
        case none
        case apiKeyHeader = "api_key_header"
        case apiKeyBearer = "api_key_bearer"
        case apiKeyQuery = "api_key_query"
    }
}

struct APITemplate: Codable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var icon: String
    var baseURL: String
    var auth: ProviderTemplateConfig.AuthMethod
    var authHeader: String?
    var authPrefix: String?
    var type: APIType
    var endpoints: [APIEndpoint]
    var skill: APISkill

    enum APIType: String, Codable, Sendable {
        case rest
        case graphql
    }
}

struct APIEndpoint: Codable, Sendable {
    var name: String
    var method: String
    var path: String
    var description: String
    var bodyType: String?
    var parameters: [String: APIParameter]?
}

struct APIParameter: Codable, Sendable {
    var type: String
    var description: String?
    var `enum`: [String]?
    var `default`: String?
    var required: Bool?
    var items: String?
}

struct APISkill: Codable, Sendable {
    var name: String
    var prompt: String
    var whenToUse: String?
}

// MARK: - AIConfigProvider Protocol

protocol AIConfigProvider: Sendable {
    func requestParams(for feature: String, model: String, override: ModelOverride?) -> AIFeatureParams
    func modelFor(feature: String) -> String
    func presetFor(model: String) -> AIConfig.ModelPreset?
    var providerTemplates: [ProviderTemplateConfig] { get }
    var apiTemplates: [APITemplate] { get }
    var modelPolicyRules: ModelPolicyRules { get }
    var agentModes: [String: AgentModeConfig] { get }
}

struct AgentModeConfig: Codable, Sendable {
    var feature: String
    var tools: [String]
    var systemPrompt: String?
    var modelTier: String?
}

// MARK: - TieredModelPolicy

actor TieredModelPolicy: ModelPolicy {
    let rules: ModelPolicyRules
    let network: NetworkMonitor
    let providerResolver: any ProviderResolver

    init(
        rules: ModelPolicyRules,
        network: NetworkMonitor = .shared,
        providerResolver: any ProviderResolver
    ) {
        self.rules = rules
        self.network = network
        self.providerResolver = providerResolver
    }

    func selectModel(
        for feature: String,
        budget: BudgetState,
        userTier: String?,
        override: ModelOverride?
    ) -> ModelSelection {
        // 1. Override model wins everything
        if let model = override?.model {
            return ModelSelection(
                model: model,
                tier: override?.tier ?? "manual",
                provider: providerTypeFor(model: model),
                reason: "override: model"
            )
        }

        // 2. Override tier wins over budget
        let tierKey: String
        if let forced = override?.tier ?? userTier {
            tierKey = forced
        } else {
            tierKey = rules.tier(for: budget.remainingPercent)
        }

        // 3. Offline? → tier "local"
        let effectiveTier = network.isAvailable ? tierKey : "local"

        // 4. Resolve model from feature table
        let model = rules.model(for: feature, tier: effectiveTier)
            ?? rules.tiers[effectiveTier]?.prefer.first
            ?? "gpt-5.1-mini"

        return ModelSelection(
            model: model,
            tier: effectiveTier,
            provider: providerTypeFor(model: model),
            reason: "config(budget: \(String(format: "%.0f", budget.remainingPercent * 100))%)"
        )
    }

    func availableModels() async -> [String] {
        guard let provider = try? await providerResolver.resolve(
            for: "chat", preference: .any, override: nil
        ) else { return [] }
        return (try? await provider.fetchModels()) ?? []
    }

    private func providerTypeFor(model: String) -> ProviderType {
        let lower = model.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
            return .openAI
        }
        if lower.hasPrefix("claude-") {
            return .anthropic
        }
        if lower.hasPrefix("gemini-") {
            return .gemini
        }
        return .openAICompatible
    }
}
