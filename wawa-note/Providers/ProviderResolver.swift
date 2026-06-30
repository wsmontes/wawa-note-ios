import Foundation
import SwiftData

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
