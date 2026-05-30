import Foundation
import UniformTypeIdentifiers

struct HTMLImporter: FormatImporter {
    let formatIdentifier = "html"
    let displayName = "HTML Document"
    let supportedUTTypes: [UTType] = [.html]

    func canRead(url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    func canRead(data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8) else { return false }
        let lower = str.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.hasPrefix("<head") || lower.hasPrefix("<body")
    }

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let html = try String(contentsOf: url, encoding: .utf8)

        // Strip HTML tags
        let plainText = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        var title = url.deletingPathExtension().lastPathComponent
        if let titleRange = html.range(of: "<title>"), let titleEnd = html.range(of: "</title>") {
            let t = String(html[titleRange.upperBound..<titleEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { title = t }
        }

        let item = KnowledgeItem(
            type: .note,
            title: title,
            status: .draft,
            bodyText: plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        item.isImported = true
        item.importSourceURL = url.absoluteString

        return ImportResult(knowledgeItem: item, artifacts: [:], warnings: [])
    }
}
