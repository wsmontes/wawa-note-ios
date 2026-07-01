import Foundation
import OSLog
import SwiftData
import UniformTypeIdentifiers
import WawaNoteCore

private let logger = Logger(subsystem: "com.wawa-note.share", category: "view-model")

enum ImportState: Equatable {
  case loading
  case importing(fileName: String, progress: String)
  case done(itemCount: Int)
  case error(String)
}

@MainActor
final class ShareExtensionViewModel: ObservableObject {
  @Published var state: ImportState = .loading

  private let extensionContext: NSExtensionContext
  private let router = ImportRouter(importers: [
    AudioImportService(), PlainTextImporter(), MarkdownImporter(),
    JSONImporter(), PDFImporter(), HTMLImporter(), RTFImporter(),
    SRTImporter(), ICSImporter(),
  ])

  init(extensionContext: NSExtensionContext) {
    self.extensionContext = extensionContext
  }

  // MARK: - Load items

  func loadItems() async {
    guard let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
      finish(with: .error("No content to import"))
      return
    }

    let providers: [NSItemProvider] = inputItems.compactMap(\.attachments).flatMap { $0 }

    guard !providers.isEmpty else {
      finish(with: .error("No content to import"))
      return
    }

    var importedCount = 0
    var errors: [String] = []

    do {
      try SharedContainer.ensureDirectories()
    } catch {
      finish(with: .error("Cannot access storage: \(error.localizedDescription)"))
      return
    }

    // Check available disk space before importing
    let freeBytes = SharedContainer.availableSpace()
    if freeBytes < 52_428_800 {
      finish(with: .error(ImportError.diskFull.localizedDescription))
      return
    }

    for (index, provider) in providers.enumerated() {
      let progress = providers.count > 1 ? "\(index + 1)/\(providers.count)" : ""
      state = .importing(fileName: "Detecting content...", progress: progress)

      do {
        let item = try await importProvider(provider)
        try await persistItem(item)
        importedCount += 1
      } catch {
        logger.error("Failed to import provider \(index): \(error.localizedDescription)")
        errors.append(error.localizedDescription)
      }
    }

    if importedCount > 0 {
      finish(with: .done(itemCount: importedCount))
    } else {
      let message = errors.first ?? "No supported content found"
      finish(with: .error(message))
    }
  }

  // MARK: - Provider type detection

  private func importProvider(_ provider: NSItemProvider) async throws -> KnowledgeItem {
    // Check types in priority order
    for type in UTType.shareableTypes {
      guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }

      switch type {
      case .audio, .movie:
        return try await importMedia(provider, type: type, itemType: .audio)
      case .image:
        return try await importMedia(provider, type: type, itemType: .image)
      case .fileURL, .data, .content:
        return try await importFile(provider)
      case .url:
        return try await importURL(provider)
      case .plainText:
        return try await importText(provider)
      default:
        continue
      }
    }

    throw ImportError.unsupportedType(provider.registeredTypeIdentifiers)
  }

  // MARK: - Media (audio/video/image)

  private func importMedia(_ provider: NSItemProvider, type: UTType, itemType: KnowledgeItemType)
    async throws -> KnowledgeItem
  {
    let url = try await loadFileRepresentation(from: provider, typeIdentifier: type.identifier)
    defer { try? FileManager.default.removeItem(at: url) }

    let originalName = provider.suggestedName ?? url.lastPathComponent
    let item = KnowledgeItem(type: itemType, title: originalName, status: .draft)
    item.isImported = true

    // Extract audio metadata
    if itemType == .audio, let audioService = router.importer(for: url) as? AudioImportService {
      let result = try await audioService.importFromURL(url)
      item.title = result.knowledgeItem.title
      item.durationSeconds = result.knowledgeItem.durationSeconds
      // Merge artifacts
      for (key, artifactURL) in result.artifacts {
        let destURL = SharedContainer.filesURL
          .appendingPathComponent(item.id.uuidString)
          .appendingPathComponent(artifactURL.lastPathComponent)
        try FileManager.default.createDirectory(
          at: destURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: artifactURL, to: destURL)
        if key == "audio" {
          item.audioFileRelativePath =
            "files/\(item.id.uuidString)/\(artifactURL.lastPathComponent)"
        }
      }
    } else {
      // Copy file to App Group
      let safeName = String.safeImportFilename(original: originalName)
      let itemDir = SharedContainer.filesURL.appendingPathComponent(item.id.uuidString)
      try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
      let destURL = itemDir.appendingPathComponent(safeName)
      try FileManager.default.copyItem(at: url, to: destURL)

      if itemType == .audio {
        item.audioFileRelativePath = "files/\(item.id.uuidString)/\(safeName)"
      } else if itemType == .image {
        item.imageFileRelativePath = "files/\(item.id.uuidString)/\(safeName)"
      }
    }

    item.importSourceURL = url.absoluteString
    return item
  }

  // MARK: - File (document)

  private func importFile(_ provider: NSItemProvider) async throws -> KnowledgeItem {
    let url = try await loadFileRepresentation(
      from: provider, typeIdentifier: UTType.data.identifier)
    defer { try? FileManager.default.removeItem(at: url) }

    let originalName = provider.suggestedName ?? url.lastPathComponent
    state = .importing(fileName: originalName, progress: "Detecting format...")

    // Try ImportRouter first
    if let importer = router.importer(for: url) {
      let result = try await importer.importFromURL(url)
      let item = result.knowledgeItem
      item.isImported = true
      item.importSourceURL = url.absoluteString

      // Copy artifacts
      let itemDir = SharedContainer.filesURL.appendingPathComponent(item.id.uuidString)
      try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
      for (key, artifactURL) in result.artifacts {
        let destURL = itemDir.appendingPathComponent(artifactURL.lastPathComponent)
        try FileManager.default.copyItem(at: artifactURL, to: destURL)
      }
      return item
    }

    // Fallback: import as plain file
    let safeName = String.safeImportFilename(original: originalName)
    let itemDir = SharedContainer.filesURL.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
    let destURL = itemDir.appendingPathComponent(safeName)
    try FileManager.default.copyItem(at: url, to: destURL)

    let item = KnowledgeItem(type: .note, title: originalName, status: .draft)
    item.isImported = true
    item.importSourceURL = url.absoluteString
    return item
  }

  // MARK: - URL

  private func importURL(_ provider: NSItemProvider) async throws -> KnowledgeItem {
    let url: URL = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if let url = item as? URL {
          continuation.resume(returning: url)
        } else if let urlString = item as? String, let url = URL(string: urlString) {
          continuation.resume(returning: url)
        } else {
          continuation.resume(throwing: ImportError.unsupportedType(["url"]))
        }
      }
    }

    let urlImporter = URLImporter()
    let result = try await urlImporter.importFromURL(url)
    result.knowledgeItem.isImported = true
    return result.knowledgeItem
  }

  // MARK: - Text

  private func importText(_ provider: NSItemProvider) async throws -> KnowledgeItem {
    let text: String = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
        item, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if let string = item as? String {
          continuation.resume(returning: string)
        } else {
          continuation.resume(throwing: ImportError.unsupportedType(["public.plain-text"]))
        }
      }
    }

    let title = String(text.prefix(100))
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)

    let item = KnowledgeItem(type: .note, title: title, status: .draft, bodyText: text)
    item.isImported = true
    return item
  }

  // MARK: - Helpers

  private func loadFileRepresentation(from provider: NSItemProvider, typeIdentifier: String)
    async throws -> URL
  {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if let url = url {
          // Copy to temp so it survives the completion handler
          let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
          do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            continuation.resume(returning: tempURL)
          } catch {
            continuation.resume(throwing: error)
          }
        } else {
          continuation.resume(throwing: ImportError.unsupportedType([typeIdentifier]))
        }
      }
    }
  }

  private func persistItem(_ item: KnowledgeItem) async throws {
    let container = try SharedContainer.makeModelContainer()
    let context = ModelContext(container)
    context.insert(item)
    try context.save()
    logger.info("Persisted item \(item.id) — type: \(item.typeRaw), title: \(item.title)")
  }

  private func finish(with state: ImportState) {
    self.state = state
    if case .done = state {
      // Auto-dismiss after brief confirmation
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        self?.extensionContext.completeRequest(returningItems: nil)
      }
    }
  }

  func cancel() {
    extensionContext.cancelRequest(
      withError: NSError(
        domain: "com.wawa-note.share",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Import cancelled"]
      ))
  }

  func dismissAfterError() {
    extensionContext.completeRequest(returningItems: nil)
  }
}

enum ImportError: LocalizedError {
  case unsupportedType([String])
  case diskFull
  case timeout

  var errorDescription: String? {
    switch self {
    case .unsupportedType(let types):
      "Unsupported content type: \(types.joined(separator: ", "))"
    case .diskFull:
      "Not enough storage space. Please free up space and try again."
    case .timeout:
      "Import took too long. The item may be incomplete."
    }
  }
}
