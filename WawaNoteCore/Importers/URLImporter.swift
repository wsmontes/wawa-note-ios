// WawaNoteCore/Importers/URLImporter.swift
import Foundation
import UniformTypeIdentifiers

/// Imports shared URLs (from Safari, etc.) as webBookmark KnowledgeItems.
struct URLImporter: FormatImporter {
  let formatIdentifier = "url"
  let displayName = "URL"
  let supportedUTTypes: [UTType] = [.url]
  let priority = 0

  func canRead(url: URL) -> Bool {
    // URLImporter handles URL objects directly via NSItemProvider,
    // not file URLs. File-based detection returns false.
    false
  }

  func canRead(data: Data) -> Bool {
    // URLs come as objects, not Data.
    false
  }

  func importFromURL(_ url: URL) async throws -> ImportResult {
    let host = url.host ?? url.absoluteString
    let title =
      host
      .replacingOccurrences(of: "www.", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))

    let item = KnowledgeItem(
      type: .webBookmark,
      title: title,
      status: .draft,
      bodyText: url.absoluteString
    )
    item.isImported = true
    item.importSourceURL = url.absoluteString

    return ImportResult(knowledgeItem: item, artifacts: [:], warnings: [])
  }
}
