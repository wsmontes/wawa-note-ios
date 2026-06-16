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
        for threshold in budget.thresholds.sorted(by: { $0.minPercent > $1.minPercent }) {
            if budgetPercent >= threshold.minPercent {
                return threshold.tier
            }
        }
        return budget.thresholds.last?.tier ?? "economy"
    }

    func model(for feature: String, tier: String) -> String? {
        features[feature]?[tier]
            ?? features["chat"]?[tier]
            ?? tiers[tier]?.prefer.first
    }
}
