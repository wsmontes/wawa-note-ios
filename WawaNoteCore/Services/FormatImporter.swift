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
  public var formatIdentifier: String { get }  public var displayName: String { get }  public var supportedUTTypes: [UTType] { get }  public var priority: Int { get }  public func canRead(url: URL) -> Bool  public func canRead(data: Data) -> Bool  public func importFromURL(_ url: URL) async throws -> ImportResult}

extension FormatImporter {
  public var priority: Int { 0 }
}
