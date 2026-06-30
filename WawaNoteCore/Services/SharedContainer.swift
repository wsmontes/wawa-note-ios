// WawaNoteCore/Services/SharedContainer.swift
import Foundation
import SwiftData

/// Centralized access to App Group shared container paths and ModelContainer factory.
/// Used by both the main app and the Share Extension to access the same data.
enum SharedContainer {
  static let appGroupIdentifier = "group.com.wawa-note"

  static var appGroupURL: URL {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      fatalError("App Group \(appGroupIdentifier) not accessible. Check entitlements.")
    }
    return url
  }

  static var databaseURL: URL {
    appGroupURL.appendingPathComponent("WawaNote.sqlite")
  }

  static var filesURL: URL {
    appGroupURL.appendingPathComponent("files", isDirectory: true)
  }

  static var tmpURL: URL {
    appGroupURL.appendingPathComponent("tmp", isDirectory: true)
  }

  /// Creates a ModelContainer backed by the shared App Group database.
  /// Call this from both the main app and the extension.
  static func makeModelContainer() throws -> ModelContainer {
    let config = ModelConfiguration(url: databaseURL)
    return try ModelContainer(
      for: KnowledgeItem.self,
      Project.self,
      TaskItem.self,
      Person.self,
      GraphEdge.self,
      Entity.self,
      configurations: config
    )
  }

  /// Ensure files and tmp directories exist.
  static func ensureDirectories() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: filesURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: tmpURL, withIntermediateDirectories: true)
  }

  /// Check available space in the App Group container (bytes).
  static func availableSpace() -> Int64 {
    guard let values = try? appGroupURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
      let capacity = values.volumeAvailableCapacity
    else {
      return 0
    }
    return Int64(capacity)
  }
}
