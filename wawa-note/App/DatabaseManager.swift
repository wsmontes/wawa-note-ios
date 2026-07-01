import Foundation
import SwiftData
import WawaNoteCore

/// Centralized database lifecycle management.
/// Extracted from WawaNoteApp to separate concerns: ModelContainer creation,
/// legacy migration, backup, and store destruction.
enum DatabaseManager {
  // MARK: - ModelContainer Creation

  /// Creates a ModelContainer with recovery from incompatible store migrations.
  /// If the on-disk store cannot be loaded (schema change, corruption, etc.),
  /// the old store is backed up, deleted, and a fresh container is created.
  static func createModelContainer(schema: Schema) -> ModelContainer {
    migrateLegacyStoreIfNeeded()
    let config = ModelConfiguration(schema: schema, url: SharedContainer.databaseURL)
    return createModelContainer(schema: schema, config: config)
  }

  // MARK: - Legacy Migration

  /// Copies legacy default.store (from default SwiftData location) to the
  /// App Group shared container as WawaNote.sqlite. Runs once — when the
  /// new store doesn't exist but the legacy store does.
  ///
  /// NOTE: commit 1c9a0ab switched the database URL from the default location
  /// to the App Group without data migration. Users who had data in the old
  /// location saw all providers/items disappear. This migration preserves it.
  private static func migrateLegacyStoreIfNeeded() {
    let newURL = SharedContainer.databaseURL
    guard !FileManager.default.fileExists(atPath: newURL.path) else { return }

    guard
      let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }

    let legacyURL = appSupport.appendingPathComponent("default.store")
    guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

    AppLog.general.info("🔄 Migrating legacy database from \(legacyURL.path) to \(newURL.path)")

    let newDir = newURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)

    let companions = ["", "-shm", "-wal"]
    for suffix in companions {
      let sourceURL = appSupport.appendingPathComponent("default.store" + suffix)
      guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
      let destFileName = "WawaNote.sqlite" + suffix
      let destURL = newDir.appendingPathComponent(destFileName)
      do {
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        AppLog.general.info("✅ Migrated default.store\(suffix) → \(destFileName)")
      } catch {
        AppLog.warn("general", "⚠️ Failed to migrate default.store\(suffix): \(error)")
      }
    }
    AppLog.general.info("✅ Legacy database migration complete")
  }

  // MARK: - Resilient Loading

  private static func createModelContainer(schema: Schema, config: ModelConfiguration)
    -> ModelContainer
  {
    do {
      return try ModelContainer(for: schema, configurations: config)
    } catch {
      AppLog.warn("general", "⚠️ ModelContainer load failed — recreating store. Error: \(error)")
      backupStoreBeforeDestroy()
      destroyAllStores()
      let freshConfig = ModelConfiguration(schema: schema, url: SharedContainer.databaseURL)
      do {
        return try ModelContainer(for: schema, configurations: freshConfig)
      } catch {
        fatalError("Could not create ModelContainer after store recreation: \(error)")
      }
    }
  }

  // MARK: - Safety Net

  /// Saves a timestamped backup before destroying the database.
  /// Backup goes to <AppGroup>/DatabaseBackups/<timestamp>/.
  private static func backupStoreBeforeDestroy() {
    guard
      let groupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: SharedContainer.appGroupIdentifier)
    else { return }

    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let backupDir = groupURL.appendingPathComponent(
      "DatabaseBackups/\(timestamp)", isDirectory: true)
    try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

    let storeNames = ["WawaNote.sqlite", "default.store"]
    let companions = ["", "-shm", "-wal"]
    var searchDirs: [URL] = [groupURL]
    if let appSupport = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    {
      searchDirs.append(appSupport)
    }

    var backedUp = 0
    for dir in searchDirs {
      for name in storeNames {
        for suffix in companions {
          let source = dir.appendingPathComponent(name + suffix)
          guard FileManager.default.fileExists(atPath: source.path) else { continue }
          let dest = backupDir.appendingPathComponent(name + suffix)
          do {
            try FileManager.default.copyItem(at: source, to: dest)
            backedUp += 1
          } catch {
            AppLog.warn("general", "⚠️ Backup failed for \(name + suffix): \(error)")
          }
        }
      }
    }

    if backedUp > 0 {
      AppLog.general.info("📦 Database backup saved to \(backupDir.path) (\(backedUp) files)")
    }
  }

  // MARK: - Destruction

  /// Deletes store files from both the app container and App Group container,
  /// covering both legacy (default.store) and current (WawaNote.sqlite) names.
  private static func destroyAllStores() {
    var searchDirs: [URL] = []

    if let appSupport = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    {
      searchDirs.append(appSupport)
    }

    if let groupURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroupIdentifier)
    {
      searchDirs.append(groupURL)
      searchDirs.append(groupURL.appendingPathComponent("Library/Application Support"))
    }

    let storeNames = ["default.store", "WawaNote.sqlite"]
    for dir in searchDirs {
      for name in storeNames {
        destroyStore(at: dir.appendingPathComponent(name))
      }
    }
  }

  /// Deletes all files associated with a Core Data / SwiftData SQLite store.
  private static func destroyStore(at url: URL) {
    let storeDir = url.deletingLastPathComponent()
    let storeFileName = url.lastPathComponent
    let companions = [storeFileName, storeFileName + "-shm", storeFileName + "-wal"]

    for fileName in companions {
      let fileURL = storeDir.appendingPathComponent(fileName)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try? FileManager.default.removeItem(at: fileURL)
        AppLog.general.info("Removed stale store file: \(fileName)")
      }
    }
  }
}
