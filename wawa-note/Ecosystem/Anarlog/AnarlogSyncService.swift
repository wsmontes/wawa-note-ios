import Foundation
import OSLog
import SwiftData
import WawaNoteCore

/// Manages bidirectional sync between a watched folder and Wawa Note's SwiftData store.
///
/// On iOS, folder access is limited by sandbox. The user must grant access
/// via `UIDocumentPickerViewController` in directory mode. A security-scoped
/// bookmark is persisted to restore access across app launches.
///
/// Sync flow:
/// 1. Scan watched folder for new/modified `.md` files
/// 2. Import new files via `AnarlogImporter`
/// 3. Track imported files in `.wawa-sync.json` to avoid duplicates
/// 4. Export modified items back to the watched folder on change
@MainActor
final class AnarlogSyncService: ObservableObject {
  @Published var isScanning = false
  @Published var lastSyncDate: Date?
  @Published var importedCount = 0
  @Published var exportedCount = 0
  @Published var syncError: String?

  private let fileStore: FileArtifactStore
  private let importer: AnarlogImporter
  private let exporter: AnarlogExporter
  private let logger = Logger(subsystem: "com.wawa.note", category: "AnarlogSync")
  private let defaults = UserDefaults.standard

  private let bookmarkKey = "anarlog_sync_bookmark"
  private let syncStateFilename = ".wawa-sync.json"

  /// Set externally (from WawaNoteApp) so scanAndImport() can persist discovered files.
  var modelContainer: ModelContainer?

  init(fileStore: FileArtifactStore = FileArtifactStore()) {
    self.fileStore = fileStore
    self.importer = AnarlogImporter()
    self.exporter = AnarlogExporter(fileStore: fileStore)
  }

  // MARK: - Folder access

  /// Save a security-scoped bookmark for the given folder URL.
  func saveBookmark(for url: URL) throws {
    let bookmark = try url.bookmarkData(
      options: [],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    defaults.set(bookmark, forKey: bookmarkKey)
    logger.info("Saved security-scoped bookmark for \(url.path)")
  }

  /// Resolve the saved bookmark to a folder URL.
  func resolveBookmark() -> URL? {
    guard let bookmark = defaults.data(forKey: bookmarkKey) else {
      return nil
    }
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark,
        options: .withoutUI,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else {
      // Bookmark is invalid; clear it
      defaults.removeObject(forKey: bookmarkKey)
      return nil
    }
    if isStale {
      // Try to recreate bookmark
      try? saveBookmark(for: url)
    }
    return url
  }

  var hasWatchedFolder: Bool {
    resolveBookmark() != nil
  }

  func clearBookmark() {
    defaults.removeObject(forKey: bookmarkKey)
    importedCount = 0
    exportedCount = 0
    lastSyncDate = nil
  }

  // MARK: - Scan & import

  /// Scan the watched folder for `.md` files and import new ones.
  func scanAndImport() async {
    guard let folderURL = resolveBookmark() else {
      syncError = "No watched folder configured"
      return
    }

    guard folderURL.startAccessingSecurityScopedResource() else {
      syncError = "Cannot access watched folder"
      return
    }
    defer { folderURL.stopAccessingSecurityScopedResource() }

    isScanning = true
    syncError = nil
    defer { isScanning = false }

    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: .skipsHiddenFiles
      ).filter { $0.pathExtension.lowercased() == "md" }

      let syncState = try readSyncState(in: folderURL)
      var newImports = 0

      for fileURL in files {
        // Check if already imported
        let filename = fileURL.lastPathComponent
        if let existingEntry = syncState.files[filename] {
          // Check if modified since last import
          let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
          if let modDate = attrs[.modificationDate] as? Date,
            modDate <= existingEntry.lastImportedAt
          {
            continue  // Not modified, skip
          }
          // File was modified — re-import
          logger.info("Re-importing modified file: \(filename)")
        }

        // Import the file
        guard let data = try? Data(contentsOf: fileURL),
          let content = String(data: data, encoding: .utf8),
          (try? AnarlogDocument.parse(from: content)) != nil
        else {
          continue
        }

        // Import the file into SwiftData
        if let container = modelContainer {
          let ctx = ModelContext(container)
          do {
            _ = try await importFile(fileURL, into: ctx)
            newImports += 1
            logger.info("Imported anarlog file: \(filename)")
          } catch {
            logger.error("Failed to import \(filename): \(error.localizedDescription)")
          }
        } else {
          newImports += 1
          logger.warning("Discovered new anarlog file but no ModelContainer set: \(filename)")
        }
      }

      importedCount += newImports
      lastSyncDate = Date()
      logger.info("Scan complete: \(newImports) new files")
    } catch {
      syncError = "Scan failed: \(error.localizedDescription)"
      logger.error("AnarlogSync scan failed: \(error)")
    }
  }

  /// Import a single discovered file. Caller provides the ModelContext.
  func importFile(_ url: URL, into modelContext: ModelContext) async throws -> KnowledgeItem {
    guard url.startAccessingSecurityScopedResource() else {
      throw SyncError.accessDenied
    }
    defer { url.stopAccessingSecurityScopedResource() }

    let result = try await importer.importFromURL(url)
    modelContext.insert(result.knowledgeItem)
    try modelContext.save()

    // Update sync state
    if let folderURL = resolveBookmark() {
      var state = (try? readSyncState(in: folderURL)) ?? SyncState()
      state.files[url.lastPathComponent] = SyncFileEntry(
        filename: url.lastPathComponent,
        itemID: result.knowledgeItem.id,
        lastImportedAt: Date(),
        contentHash: try? sha256(of: url)
      )
      try writeSyncState(state, in: folderURL)
    }

    return result.knowledgeItem
  }

  // MARK: - Export

  /// Export an item to the watched folder.
  func exportItem(_ item: KnowledgeItem) async throws {
    guard let folderURL = resolveBookmark() else {
      throw SyncError.noWatchedFolder
    }
    guard folderURL.startAccessingSecurityScopedResource() else {
      throw SyncError.accessDenied
    }
    defer { folderURL.stopAccessingSecurityScopedResource() }

    let markdown = try exporter.exportMarkdown(item: item)
    let safeTitle = item.title
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let fileURL = folderURL.appendingPathComponent("\(safeTitle).md")
    try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    exportedCount += 1
    logger.info("Exported '\(item.title)' → \(fileURL.lastPathComponent)")
  }

  // MARK: - Sync state

  private func syncStateURL(in folder: URL) -> URL {
    folder.appendingPathComponent(syncStateFilename)
  }

  private func readSyncState(in folder: URL) throws -> SyncState {
    let url = syncStateURL(in: folder)
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url)
    else {
      return SyncState()
    }
    return (try? JSONDecoder().decode(SyncState.self, from: data)) ?? SyncState()
  }

  private func writeSyncState(_ state: SyncState, in folder: URL) throws {
    let url = syncStateURL(in: folder)
    let data = try JSONEncoder().encode(state)
    try data.write(to: url, options: .atomic)
  }

  // MARK: - Types

  enum SyncError: Error, LocalizedError {
    case noWatchedFolder
    case accessDenied

    var errorDescription: String? {
      switch self {
      case .noWatchedFolder: return "No watched folder configured"
      case .accessDenied: return "Cannot access the watched folder"
      }
    }
  }

  private struct SyncState: Codable {
    var files: [String: SyncFileEntry] = [:]
    var lastFullScan: Date?
  }

  private struct SyncFileEntry: Codable {
    let filename: String
    let itemID: UUID
    let lastImportedAt: Date
    let contentHash: String?
  }
}

// MARK: - SHA256 helper

private func sha256(of url: URL) throws -> String {
  // Simplified: use file modification date as proxy
  // Full SHA would require CryptoKit and reading the file
  let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
  if let modDate = attrs[.modificationDate] as? Date {
    return "\(Int(modDate.timeIntervalSince1970))"
  }
  return "unknown"
}
