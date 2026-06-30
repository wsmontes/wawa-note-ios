import Foundation
import UniformTypeIdentifiers

// Related JIRA: KAN-12, KAN-62

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
        let text = try await Task.detached { try String(contentsOf: url, encoding: .utf8) }.value
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

                // YAML frontmatter parser — handles scalar values, lists, booleans,
                // numbers, quoted strings, and multiline block scalars (| and >)
                var currentKey: String?
                let lines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false)
                var i = 0
                while i < lines.count {
                    let trimmed = String(lines[i]).trimmingCharacters(in: .whitespaces)
                    defer { i += 1 }

                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    if !trimmed.first!.isLetter { continue }  // skip non-key lines

                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let valueStr = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                        // Strip surrounding quotes, preserving internal quotes
                        let value: String = {
                            if valueStr.hasPrefix("\"") && valueStr.hasSuffix("\"") {
                                return String(valueStr.dropFirst().dropLast())
                            }
                            if valueStr.hasPrefix("'") && valueStr.hasSuffix("'") {
                                return String(valueStr.dropFirst().dropLast())
                            }
                            return valueStr
                        }()

                        // Multiline block scalar — consume indented continuation lines
                        if value == "|" || value == ">" {
                            var blockLines: [String] = []
                            while i + 1 < lines.count {
                                let next = String(lines[i + 1])
                                if next.first?.isWhitespace == true || next.isEmpty {
                                    blockLines.append(next.trimmingCharacters(in: .whitespaces))
                                    i += 1
                                } else {
                                    break
                                }
                            }
                            MarkdownImporter.applyFrontmatter(&title, &date, &durationSeconds, &type, &tags, key, blockLines.joined(separator: "\n"))
                            continue
                        }

                        MarkdownImporter.applyFrontmatter(&title, &date, &durationSeconds, &type, &tags, key, value)
                        currentKey = key
                    } else if trimmed.hasPrefix("- "), let parentKey = currentKey {
                        // List item under previous key (e.g., tags: \n  - foo)
                        let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                        if parentKey == "tags", !item.isEmpty { tags.append(item) }
                    }
                }
            }
        }

        // Parse body sections
        let body = String(text[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract title from first H1 outside a fenced code block
        var inFencedBlock = false
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFencedBlock.toggle()
                continue
            }
            if !inFencedBlock, trimmed.hasPrefix("# ") {
                let extractedTitle = trimmed.replacingOccurrences(of: "# ", with: "").trimmingCharacters(in: .whitespaces)
                if !extractedTitle.isEmpty { title = extractedTitle }
                break
            }
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

    /// Applies a parsed frontmatter key-value pair to the extraction state.
    private static func applyFrontmatter(
        _ title: inout String, _ date: inout Date?, _ duration: inout Double?,
        _ type: inout KnowledgeItemType, _ tags: inout [String],
        _ key: String, _ value: String
    ) {
        switch key {
        case "title": title = value
        case "date":
            date = ISO8601DateFormatter().date(from: value)
            if date == nil {
                let alt = DateFormatter()
                alt.dateFormat = "yyyy-MM-dd"
                date = alt.date(from: value)
            }
        case "duration": duration = Double(value)
        case "type": type = KnowledgeItemType(rawValue: value) ?? .note
        case "tags":
            if value.hasPrefix("[") {
                tags = value.dropFirst().dropLast().split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "'", with: "")
                }
            } else {
                tags.append(value)
            }
        default: break
        }
    }
}
