import Foundation
import SwiftData

/// Manages which AI provider is currently active. When multiple providers
/// are configured, features use the active one. Persists choice in UserDefaults.
final class ActiveProviderManager: @unchecked Sendable {
    static let shared = ActiveProviderManager()

    private let defaults = UserDefaults.standard
    private let key = "active_provider_id"

    func getActiveProviderID() -> UUID? {
        guard let idString = defaults.string(forKey: key) else { return nil }
        return UUID(uuidString: idString)
    }

    func setActiveProviderID(_ id: UUID) {
        defaults.set(id.uuidString, forKey: key)
    }

    func getActiveProvider(context: ModelContext) -> AIProviderConfigModel? {
        guard let activeId = getActiveProviderID() else {
            // No active set, return first available
            let descriptor = FetchDescriptor<AIProviderConfigModel>()
            return try? context.fetch(descriptor).first
        }
        let descriptor = FetchDescriptor<AIProviderConfigModel>(
            predicate: #Predicate { $0.id == activeId }
        )
        return try? context.fetch(descriptor).first ?? {
            // Active provider was deleted, fall back to first available
            let fallback = FetchDescriptor<AIProviderConfigModel>()
            return try? context.fetch(fallback).first
        }()
    }
}
