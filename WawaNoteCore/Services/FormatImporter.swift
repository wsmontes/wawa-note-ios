import Foundation
import UniformTypeIdentifiers

struct ImportResult {
  let knowledgeItem: KnowledgeItem
  let artifacts: [String: URL]
  let warnings: [String]
}

protocol FormatImporter: Sendable {
  var formatIdentifier: String { get }
  var displayName: String { get }
  var supportedUTTypes: [UTType] { get }
  var priority: Int { get }
  func canRead(url: URL) -> Bool
  func canRead(data: Data) -> Bool
  func importFromURL(_ url: URL) async throws -> ImportResult
}

extension FormatImporter {
  var priority: Int { 0 }
}
