import Foundation

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
    ) -> ModelSelection

    func availableModels() async -> [String]
}

// MARK: - Config Types (populated by JSON config parsing)

struct ProviderTemplateConfig: Codable, Sendable {
    var id: String
    var displayName: String
    var providerType: String
    var template: [String: String]
}

struct APITemplate: Codable, Sendable {
    var id: String
    var baseURL: String
    var authType: String
    var headers: [String: String]?
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
