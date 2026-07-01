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

  /// Schema shared between main app and Share Extension.
  /// Includes every @Model type available in WawaNoteCore so both processes
  /// compute compatible version hashes. The main app's Schema in
  /// WawaNoteApp.swift extends this with 3 additional types
  /// (AIProviderConfigModel, Folder, Annotation) from the main app target.
  /// These are NOT in WawaNoteCore so the Share Extension cannot reference
  /// them — the resulting lightweight migration (adding tables) is handled
  /// automatically by Core Data.
  public static let sharedSchema = Schema([
    KnowledgeItem.self,
    Project.self,
    TaskItem.self,
    Person.self,
    GraphEdge.self,
    Entity.self,
    ProjectFrame.self,
    ChangeRecord.self,
    ProjectSnapshot.self,
    AgentSuggestion.self,
    QueueEntry.self,
    ProjectDerivedItem.self,
  ])

  /// Creates a ModelContainer backed by the shared App Group database.
  /// Uses the full WawaNoteCore schema so both the main app and the Share
  /// Extension produce the same store metadata — preventing spurious
  /// "store incompatible" errors that trigger destructive recovery.
  public static func makeModelContainer() throws -> ModelContainer {
    let config = ModelConfiguration(schema: sharedSchema, url: databaseURL)
    return try ModelContainer(for: sharedSchema, configurations: config)
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
