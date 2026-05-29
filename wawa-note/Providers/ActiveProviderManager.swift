import Foundation
import SwiftData

final class ActiveProviderManager: @unchecked Sendable {
    static let shared = ActiveProviderManager()
    private let defaults = UserDefaults.standard
    private let key = "active_provider_id"

    func getActiveProviderID() -> String? {
        defaults.string(forKey: key)
    }

    func setActiveProviderID(_ id: String) {
        defaults.set(id, forKey: key)
    }

    func getActiveProvider(context: ModelContext) -> AIProviderConfigModel? {
        guard let activeId = getActiveProviderID(),
              let uuid = UUID(uuidString: activeId) else {
            let descriptor = FetchDescriptor<AIProviderConfigModel>()
            return try? context.fetch(descriptor).first
        }
        let descriptor = FetchDescriptor<AIProviderConfigModel>(predicate: #Predicate { $0.id == uuid })
        return try? context.fetch(descriptor).first ?? {
            let fallback = FetchDescriptor<AIProviderConfigModel>()
            return try? context.fetch(fallback).first
        }()
    }
}
