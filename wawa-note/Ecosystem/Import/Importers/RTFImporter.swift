import Foundation
import UniformTypeIdentifiers

// Related JIRA: KAN-12, KAN-62

struct RTFImporter: FormatImporter {
    let formatIdentifier = "rtf"
    let displayName = "Rich Text"
    let supportedUTTypes: [UTType] = [.rtf]

    func canRead(url: URL) -> Bool { url.pathExtension.lowercased() == "rtf" }
    func canRead(data: Data) -> Bool {
        guard let str = String(data: data, encoding: .ascii) else { return false }
        return str.hasPrefix("{\\rtf")
    }

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let data = try await Task.detached { try Data(contentsOf: url) }.value

        // Try NSAttributedString first, fall back to stripping RTF tags
        let text: String
        let rtfOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        if let attr = try? NSAttributedString(data: data, options: rtfOptions, documentAttributes: nil) {
            text = attr.string
        } else {
            // Fallback: basic RTF tag stripping. Note: deeply nested braces
            // may produce garbled output — NSAttributedString path is preferred.
            guard let raw = String(data: data, encoding: .ascii) else {
                throw NSError(domain: "RTFImporter", code: 1)
            }
            var stripped = raw
            // Iteratively remove innermost brace groups to handle nesting
            for _ in 0..<10 {
                let before = stripped
                stripped = stripped.replacingOccurrences(of: "\\{[^{}]*\\}", with: "", options: .regularExpression)
                if stripped == before { break }  // no more groups to remove
            }
            text =
                stripped
                .replacingOccurrences(of: "\\\\[a-z]+\\d*\\s?", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\\n", with: "")
        }

        let title = url.deletingPathExtension().lastPathComponent
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? title

        let item = KnowledgeItem(
            type: .note,
            title: String(firstLine.prefix(100)),
            status: .draft,
            bodyText: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        item.isImported = true
        item.importSourceURL = url.absoluteString

        return ImportResult(knowledgeItem: item, artifacts: [:], warnings: [])
    }
}
