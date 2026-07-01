// WawaNoteCore/Extensions/String+Sanitization.swift
import Foundation

extension String {
  /// Sanitize a filename for safe storage. Prepends a UUID prefix to avoid collisions.
  public static func safeImportFilename(original: String) -> String {
    let sanitized =
      original
      .replacingOccurrences(
        of: "[^a-zA-Z0-9._-]",
        with: "_",
        options: .regularExpression
      )
    return "\(UUID().uuidString)-\(sanitized)"
  }

  /// Returns nil if the string is empty (after trimming whitespace).
  /// Used by providers to suppress empty system prompts and similar.
  public var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : self
  }
}
