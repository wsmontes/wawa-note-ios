import Foundation
import UniformTypeIdentifiers

final class MarkdownImporter: FormatImporter, @unchecked Sendable {
    let formatIdentifier = "markdown"
    let displayName = "Markdown"
    let supportedUTTypes: [UTType] = [.plainText]

    func canRead(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "txt"
    }

    func canRead(data: Data) -> Bool {
        // Check for YAML frontmatter or markdown heading
        if let str = String(data: data.prefix(1024), encoding: .utf8) {
            return str.hasPrefix("---") || str.hasPrefix("# ") || str.contains("\n---\n")
        }
        return false
    }

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        var warnings: [String] = []

        // Parse YAML frontmatter
        var title = url.deletingPathExtension().lastPathComponent
        var tags: [String] = []
        var date: Date?
        var durationSeconds: Double?
        var type: KnowledgeItemType = .note
        var bodyStart = text.startIndex

        if text.hasPrefix("---") {
            let rest = text.dropFirst(3)
            if let endRange = rest.range(of: "\n---\n") {
                let frontmatter = String(rest[..<endRange.lowerBound])
                bodyStart = endRange.upperBound

                // Simple YAML parsing (no Yams dependency needed for basic fields)
                for line in frontmatter.split(separator: "\n") {
                    let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        var value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                        value = value.replacingOccurrences(of: "\"", with: "")

                        switch key {
                        case "title": title = value
                        case "date": date = ISO8601DateFormatter().date(from: value)
                        case "duration": durationSeconds = Double(value)
                        case "type": type = KnowledgeItemType(rawValue: value) ?? .note
                        case "tags":
                            if value.hasPrefix("[") {
                                tags = value.dropFirst().dropLast().split(separator: ",").map {
                                    String($0).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                                }
                            }
                        default: break
                        }
                    }
                }
            }
        }

        // Parse body sections
        let body = String(text[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("# ") {
            let firstLine = body.split(separator: "\n").first ?? ""
            let extractedTitle = String(firstLine).replacingOccurrences(of: "# ", with: "").trimmingCharacters(in: .whitespaces)
            if !extractedTitle.isEmpty { title = extractedTitle }
        }

        let item = KnowledgeItem(
            type: type,
            title: title,
            createdAt: date ?? Date(),
            status: .draft,
            tags: tags,
            bodyText: body,
            durationSeconds: durationSeconds
        )
        item.isImported = true
        item.importSourceURL = url.absoluteString

        if date == nil { warnings.append("No date in frontmatter, using current date") }

        return ImportResult(knowledgeItem: item, artifacts: ["content.md": url], warnings: warnings)
    }
}
