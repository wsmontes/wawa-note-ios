// WawaNoteCore/Extensions/String+Sanitization.swift
import Foundation

extension String {
  /// Sanitize a filename for safe storage. Prepends a UUID prefix to avoid collisions.
  static func safeImportFilename(original: String) -> String {
    let sanitized =
      original
      .replacingOccurrences(
        of: "[^a-zA-Z0-9._-]",
        with: "_",
        options: .regularExpression
      )
    return "\(UUID().uuidString)-\(sanitized)"
  }
}
