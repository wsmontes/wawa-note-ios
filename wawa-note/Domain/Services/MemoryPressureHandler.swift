import Foundation
import SwiftUI

// MARK: - Memory Pressure Handler

/// Centralised handler for `UIApplication.didReceiveMemoryWarningNotification`.
///
/// Services register cleanup closures at startup. When a memory warning fires,
/// all registered handlers run in order — lightest first, heaviest last.
///
/// Usage:
/// ```swift
/// // In App init or ContentView.onAppear:
/// MemoryPressureHandler.shared.register("Clear search cache") {
///   SearchService().clearCache()
/// }
/// MemoryPressureHandler.shared.register("Clear URL cache") {
///   URLCache.shared.removeAllCachedResponses()
/// }
/// ```
@MainActor
final class MemoryPressureHandler: @unchecked Sendable {
  static let shared = MemoryPressureHandler()

  private var handlers: [(label: String, cleanup: @MainActor @Sendable () -> Void)] = []
  private var isObserving = false

  private init() {}

  /// Register a cleanup closure. Handlers run FIFO on each warning.
  /// - Parameters:
  ///   - label: Human-readable description for logging
  ///   - cleanup: The cleanup work — keep it fast and synchronous
  func register(_ label: String, cleanup: @MainActor @Sendable @escaping () -> Void) {
    handlers.append((label, cleanup))
    AppLog.event("memory", "Registered pressure handler: \(label) (total: \(handlers.count))")

    if !isObserving {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(onPressure),
        name: UIApplication.didReceiveMemoryWarningNotification,
        object: nil
      )
      isObserving = true
      AppLog.event("memory", "MemoryPressureHandler observing notifications")
    }
  }

  @objc private func onPressure() {
    AppLog.warn("memory", "Memory warning received — running \(handlers.count) handler(s)")
    for (label, cleanup) in handlers {
      cleanup()
      AppLog.debug("memory", "Ran cleanup: \(label)")
    }
  }
}
