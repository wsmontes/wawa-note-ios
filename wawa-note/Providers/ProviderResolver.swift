import Foundation
import SwiftData
// Related JIRA: KAN-9, KAN-42


// MARK: - ProviderResolver Protocol

protocol ProviderResolver: Sendable {
    func resolve(
        for feature: String,
        preference: ProviderPreference,
        override: ModelOverride?
    ) async throws -> any AIProvider

    var activeProviderID: String { get async }
    func setActiveProvider(_ id: String) async
}
