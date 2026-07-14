import Foundation
import OSLog
import SwiftData

// MARK: - Safe save with structured logging

/// Replaces `try? modelContext.save()` with proper error handling.
/// Critical state transitions (item status changes, crash recovery,
/// pipeline completion) must use `safeSave` to surface persistence failures
/// instead of silently discarding them.
///
/// Guideline: "Nunca use try? em operações de persistência críticas.
/// Um save que falha silenciosamente é data loss em slow motion."
extension ModelContext {

  /// Save with structured error logging. Returns true on success.
  /// Use for critical state transitions where a failed save means data loss.
  ///
  /// - Parameters:
  ///   - context: A short label for the operation (e.g., "crash-recovery", "transcription-complete")
  ///   - itemId: Optional item UUID for log correlation
  /// - Returns: `true` if save succeeded, `false` if it failed (error is logged)
  @discardableResult
  func safeSave(context label: String, itemId: UUID? = nil) -> Bool {
    do {
      try save()
      return true
    } catch {
      let itemStr = itemId.map { $0.uuidString.prefix(8).description } ?? "nil"
      let msg = "💾 SAVE FAILED [\(label)] item=\(itemStr): \(error.localizedDescription)"
      AppLog.storage.error("\(msg)")
      AppLog.error("storage", msg)

      // Attempt to surface to user via notification (non-blocking).
      // UI can observe this to show a toast/banner.
      NotificationCenter.default.post(
        name: .persistenceError,
        object: nil,
        userInfo: [
          "context": label,
          "itemId": itemId as Any,
          "error": error.localizedDescription,
        ]
      )
      return false
    }
  }
}

// MARK: - Notification name

extension Notification.Name {
  /// Posted when a critical `modelContext.save()` fails.
  /// UI layers can observe this to show error banners.
  static let persistenceError = Notification.Name("com.wawa-note.persistenceError")
}
