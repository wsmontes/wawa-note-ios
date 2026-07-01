import Foundation
import UniformTypeIdentifiers

public struct ImportResult {
  public let knowledgeItem: KnowledgeItem
  public let artifacts: [String: URL]
  public let warnings: [String]

  public init(knowledgeItem: KnowledgeItem, artifacts: [String: URL], warnings: [String]) {
    self.knowledgeItem = knowledgeItem
    self.artifacts = artifacts
    self.warnings = warnings
  }
}

public protocol FormatImporter: Sendable {
  var formatIdentifier: String { get }
  var displayName: String { get }
  var supportedUTTypes: [UTType] { get }
  var priority: Int { get }
  func canRead(url: URL) -> Bool
  func canRead(data: Data) -> Bool
  func importFromURL(_ url: URL) async throws -> ImportResult
}

extension FormatImporter {
  public var priority: Int { 0 }
}
