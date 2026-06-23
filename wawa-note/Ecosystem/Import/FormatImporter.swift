import Foundation
import UniformTypeIdentifiers
// Related JIRA: KAN-12, KAN-62


struct ImportResult {
    let knowledgeItem: KnowledgeItem
    let artifacts: [String: URL]
    let warnings: [String]
}

/// Protocol for importing external file formats into Wawa Note KnowledgeItems.
///
/// Each importer handles a specific file format, declaring which UTTypes it supports.
/// `ImportRouter` resolves the correct importer for a given file URL.
///
/// ## Implementations (10)
/// - `PlainTextImporter` (.txt), `MarkdownImporter` (.md), `JSONImporter` (.json)
/// - `PDFImporter`, `HTMLImporter`, `RTFImporter`, `SRTImporter`, `ICSImporter`
/// - `GitHubIssuesImporter`, `AudioImportService`
///
/// ## Related Docs
/// - `docs/USER_JOURNEYS.md` — Import journey
protocol FormatImporter: Sendable {
    /// Unique identifier for this importer (e.g., "markdown", "pdf").
    var formatIdentifier: String { get }
    /// Human-readable name shown in import preview.
    var displayName: String { get }
    /// UTType identifiers this importer can handle.
    var supportedUTTypes: [UTType] { get }
    var priority: Int { get }
    func canRead(url: URL) -> Bool
    func canRead(data: Data) -> Bool
    func importFromURL(_ url: URL) async throws -> ImportResult
}

extension FormatImporter {
    var priority: Int { 0 }
}
