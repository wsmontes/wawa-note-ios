// WawaNoteCore/Services/SharedContainer.swift
import Foundation
import SwiftData

/// Centralized access to App Group shared container paths and ModelContainer factory.
/// Used by both the main app and the Share Extension to access the same data.
public enum SharedContainer {
  public static let appGroupIdentifier = "group.com.wawa-note"

  public static var appGroupURL: URL {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      fatalError("App Group \(appGroupIdentifier) not accessible. Check entitlements.")
    }
    return url
  }

  public static var databaseURL: URL {
    appGroupURL.appendingPathComponent("WawaNote.sqlite")
  }

  public static var filesURL: URL {
    appGroupURL.appendingPathComponent("files", isDirectory: true)
  }

  public static var tmpURL: URL {
    appGroupURL.appendingPathComponent("tmp", isDirectory: true)
  }

  /// Creates a ModelContainer backed by the shared App Group database.
  /// Call this from both the main app and the extension.
  public static func makeModelContainer() throws -> ModelContainer {
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
  public static func ensureDirectories() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: filesURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: tmpURL, withIntermediateDirectories: true)
  }

  /// Check available space in the App Group container (bytes).
  public static func availableSpace() -> Int64 {
    guard let values = try? appGroupURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
      let capacity = values.volumeAvailableCapacity
    else {
      return 0
    }
    return Int64(capacity)
  }
}
