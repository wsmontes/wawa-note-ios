import Foundation
import UniformTypeIdentifiers

public struct PlainTextImporter: FormatImporter {
  public init() {}
  public let formatIdentifier = "txt"
  public let displayName = "Plain Text"
  public let supportedUTTypes: [UTType] = [.plainText, .text]

  public func canRead(url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "txt" || ext == "text"
  }

  public func canRead(data: Data) -> Bool {
    String(data: data, encoding: .utf8) != nil
  }

  public func importFromURL(_ url: URL) async throws -> ImportResult {
    let text = try String(contentsOf: url, encoding: .utf8)
    let title = url.deletingPathExtension().lastPathComponent
    let firstLine = text.split(separator: "\n").first.map(String.init) ?? title

    let item = KnowledgeItem(
      type: .note,
      title: String(firstLine.prefix(100)),
      status: .draft,
      bodyText: text
    )
    item.isImported = true
    item.importSourceURL = url.absoluteString

    return ImportResult(knowledgeItem: item, artifacts: [:], warnings: [])
  }
}
