import Foundation

// MARK: - Anarlog Frontmatter Types

/// Full frontmatter structure for an anarlog session note.
/// Mirrors the Rust types in `crates/template-app/src/types.rs`.
struct AnarlogFrontmatter: Codable, Equatable {
    var title: String?
    var date: Date?
    var duration: Double?
    var participants: [AnarlogParticipant]?
    var transcript: AnarlogTranscript?
    var template: AnarlogTemplate?
    var tags: [String]?
    var session: AnarlogSession?
}

/// A meeting participant with optional job title.
/// Mirrors anarlog's `Participant` struct.
struct AnarlogParticipant: Codable, Equatable {
    var name: String
    var jobTitle: String?

    enum CodingKeys: String, CodingKey {
        case name
        case jobTitle = "job_title"
    }
}

/// Transcript data containing speaker-labeled segments.
/// Mirrors anarlog's `Transcript` struct.
struct AnarlogTranscript: Codable, Equatable {
    var segments: [AnarlogSegment]
}

/// A single transcript segment — speaker + text.
/// Mirrors anarlog's `Segment` struct.
struct AnarlogSegment: Codable, Equatable {
    var speaker: String
    var text: String
}

/// Template definition for structured note output.
/// Mirrors anarlog's `EnhanceTemplate` struct.
struct AnarlogTemplate: Codable, Equatable {
    var title: String
    var description: String?
    var sections: [AnarlogTemplateSection]?
}

/// A section within a note template.
/// Mirrors anarlog's `TemplateSection` struct.
struct AnarlogTemplateSection: Codable, Equatable {
    var title: String
    var description: String?
}

/// Session metadata (calendar event info).
/// Mirrors anarlog's `Session` struct.
struct AnarlogSession: Codable, Equatable {
    var title: String?
    var startedAt: String?
    var endedAt: String?
    var event: AnarlogEvent?

    enum CodingKeys: String, CodingKey {
        case title
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case event
    }
}

/// A calendar event reference.
/// Mirrors anarlog's `Event` struct.
struct AnarlogEvent: Codable, Equatable {
    var name: String
}

// MARK: - Anarlog Document

/// A complete anarlog session document: YAML frontmatter + Markdown body.
///
/// Format:
/// ```
/// ---
/// title: "Meeting Title"
/// date: 2025-06-08T10:00:00Z
/// ---
/// # Summary
/// Content here...
/// ```
///
/// Round-trip fidelity: `parse(from:)` followed by `render()` produces
/// identical output (modulo key ordering, which is alphabetically sorted
/// to match anarlog's `serde_yaml` + `sort_value` behavior).
struct AnarlogDocument: Equatable {
    var frontmatter: AnarlogFrontmatter
    var content: String

    // MARK: - Parse

    enum ParseError: Error, LocalizedError {
        case missingOpeningDelimiter
        case missingClosingDelimiter
        case invalidYAML(String)
        case typeMismatch(String)

        var errorDescription: String? {
            switch self {
            case .missingOpeningDelimiter:
                return "Document must start with '---'"
            case .missingClosingDelimiter:
                return "Frontmatter must be closed with '---'"
            case .invalidYAML(let msg):
                return "Invalid YAML: \(msg)"
            case .typeMismatch(let msg):
                return "Type mismatch: \(msg)"
            }
        }
    }

    /// Parse an anarlog document from a raw markdown string.
    static func parse(from markdown: String) throws -> AnarlogDocument {
        let normalized = normalizeLineEndings(markdown)
        let trimmed = normalized.trimmingCharacters(in: .whitespaces)

        guard trimmed.hasPrefix("---") else {
            throw ParseError.missingOpeningDelimiter
        }

        // Find closing delimiter
        let afterOpening = String(trimmed.dropFirst(3))

        // Skip the newline after opening delimiter
        let yamlStart: String
        if afterOpening.hasPrefix("\n") {
            yamlStart = String(afterOpening.dropFirst())
        } else {
            yamlStart = afterOpening
        }

        // Find closing --- on its own line
        guard let closingRange = findClosingDelimiter(in: yamlStart) else {
            throw ParseError.missingClosingDelimiter
        }

        let yamlString = String(yamlStart[..<closingRange.lowerBound])
        let afterClosing = yamlStart[closingRange.upperBound...]

        // Parse YAML → JSON → Codable
        let yamlDict = try MinimalYAMLParser.parse(yamlString)

        // Convert Date strings to actual Dates for JSONDecoder
        // We handle dates manually because they come in as strings
        let jsonCompatible = makeJSONCompatible(yamlDict)

        let jsonData = try JSONSerialization.data(withJSONObject: jsonCompatible, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let frontmatter = try decoder.decode(AnarlogFrontmatter.self, from: jsonData)

        // Content: skip the line ending after ---
        var contentStart = String(afterClosing)
        if contentStart.hasPrefix("\n") {
            contentStart = String(contentStart.dropFirst())
        }

        // Preserve content with original line endings (after normalization to \n)
        let content = contentStart.trimmingCharacters(in: .newlines)

        return AnarlogDocument(frontmatter: frontmatter, content: content)
    }

    private static func normalizeLineEndings(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
         .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func findClosingDelimiter(in text: String) -> Range<String.Index>? {
        // Find "\n---\n" or "\n---" at end of string
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            guard let newlineIdx = text[searchStart...].firstIndex(of: "\n") else { break }
            let afterNewline = text.index(after: newlineIdx)

            if afterNewline < text.endIndex,
               text[afterNewline...].hasPrefix("---") {
                let dashEnd = text.index(afterNewline, offsetBy: 3)
                // Check: after --- must be \n or end of string
                if dashEnd == text.endIndex || text[dashEnd] == "\n" {
                    return newlineIdx..<dashEnd
                }
            }
            searchStart = afterNewline
        }
        // Also check: "---" at very start of yamlStart (empty frontmatter)
        if text.hasPrefix("---") {
            let dashEnd = text.index(text.startIndex, offsetBy: 3)
            if dashEnd == text.endIndex || text[dashEnd] == "\n" {
                return text.startIndex..<dashEnd
            }
        }
        return nil
    }

    /// Recursively convert parsed YAML values to JSON-compatible types.
    /// Handles ISO 8601 date strings → RFC 3339 for JSONDecoder.
    private static func makeJSONCompatible(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { makeJSONCompatible($0) }
        case let arr as [Any]:
            return arr.map { makeJSONCompatible($0) }
        case let s as String:
            return s
        default:
            return value
        }
    }

    // MARK: - Render

    /// Render the document back to a markdown string in anarlog format.
    /// Keys are sorted alphabetically (matching anarlog's `sort_value`).
    func render() throws -> String {
        // Convert frontmatter → JSON → [String: Any] → YAML
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(frontmatter)
        let jsonDict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] ?? [:]

        let yamlString = MinimalYAMLSerializer.serialize(jsonDict)

        var output = "---\n"
        if !yamlString.isEmpty {
            output += yamlString
        }
        output += "---\n"
        if !content.isEmpty {
            output += "\n"
            output += content
        }
        // Ensure trailing newline
        if !output.hasSuffix("\n") {
            output += "\n"
        }
        return output
    }
}

// MARK: - Minimal YAML Parser

/// Parses a minimal YAML subset — exactly what anarlog's `serde_yaml` produces.
///
/// Supported:
/// - Key-value pairs with `: ` separator
/// - Nested objects via 2-space indentation
/// - Arrays via `- ` prefix
/// - Quoted and unquoted string values
/// - Numbers, booleans (true/false), null
///
/// Not supported (not used by anarlog):
/// - Anchors, aliases, tags
/// - Multi-line strings (|, >)
/// - Flow style ({}, [])
/// - Complex key types
private enum MinimalYAMLParser {
    static func parse(_ yaml: String) throws -> [String: Any] {
        let lines = yaml.components(separatedBy: "\n")
        var index = 0
        let (result, _) = try parseObject(lines: lines, index: &index, currentIndent: 0)
        return result
    }

    private static func parseObject(lines: [String], index: inout Int, currentIndent: Int) throws -> ([String: Any], Int) {
        var result: [String: Any] = [:]

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty or comment line — skip
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            let indent = countLeadingSpaces(line)

            // If indent is less than current, we're done with this object
            if indent < currentIndent {
                return (result, index)
            }

            // Array item at object level — shouldn't happen; arrays are values of keys
            if trimmed.hasPrefix("- ") {
                let (_, newIndex) = try parseArray(lines: lines, index: &index, baseIndent: indent)
                index = newIndex
                continue
            }

            // Key-value pair
            guard let colonIdx = findKeyValueColon(in: trimmed) else {
                // Line without a colon at this indent might be malformed; skip gracefully
                index += 1
                continue
            }

            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let afterColon = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

            if afterColon.isEmpty {
                // Nested object or array starts on next lines
                index += 1
                if index < lines.count {
                    let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("- ") {
                        let (arr, newIndex) = try parseArray(lines: lines, index: &index, baseIndent: indent)
                        index = newIndex
                        result[key] = arr
                    } else {
                        let (obj, newIndex) = try parseObject(lines: lines, index: &index, currentIndent: indent + 2)
                        index = newIndex
                        result[key] = obj
                    }
                }
            } else {
                // Scalar value
                result[key] = parseScalar(afterColon)
                index += 1
            }
        }
        return (result, index)
    }

    private static func parseArray(lines: [String], index: inout Int, baseIndent: Int) throws -> ([Any], Int) {
        var result: [Any] = []
        let arrayIndent = baseIndent + 2  // items are indented 2 more than the key

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            let indent = countLeadingSpaces(line)

            // If we're back to base indent or less, array is done
            if indent <= baseIndent {
                break
            }

            if trimmed.hasPrefix("- ") {
                let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)

                if value.isEmpty {
                    // Array of objects: item fields on following lines
                    index += 1
                    let (obj, newIndex) = try parseObject(lines: lines, index: &index, currentIndent: indent + 2)
                    index = newIndex
                    if !obj.isEmpty {
                        result.append(obj)
                    }
                } else if let colonIdx = findKeyValueColon(in: value) {
                    // Array of objects, first field on same line as dash
                    let key = String(value[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let afterColon = value[value.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

                    var obj: [String: Any] = [:]
                    if afterColon.isEmpty {
                        // Remaining fields on next lines
                        index += 1
                        let (restObj, newIndex) = try parseObject(lines: lines, index: &index, currentIndent: indent + 2)
                        index = newIndex
                        obj = restObj
                        obj[key] = ""  // Placeholder, restObj will override if it has the same key
                    } else {
                        obj[key] = parseScalar(afterColon)
                        index += 1
                        // Check for more fields at same indent level
                        let (restObj, newIndex2) = try parseObject(lines: lines, index: &index, currentIndent: indent + 2)
                        index = newIndex2
                        for (k, v) in restObj { obj[k] = v }
                    }
                    result.append(obj)
                } else {
                    // Simple scalar array item
                    result.append(parseScalar(value))
                    index += 1
                }
            } else if indent > arrayIndent {
                // Continued object fields for the previous array item
                // Back up and let parseObject handle it
                let (obj, newIndex) = try parseObject(lines: lines, index: &index, currentIndent: arrayIndent + 2)
                index = newIndex
                if !obj.isEmpty, let lastIdx = result.indices.last {
                    if var lastObj = result[lastIdx] as? [String: Any] {
                        for (k, v) in obj { lastObj[k] = v }
                        result[lastIdx] = lastObj
                    }
                }
            } else {
                // Indent went back up — array is done
                break
            }
        }
        return (result, index)
    }

    private static func countLeadingSpaces(_ line: String) -> Int {
        var count = 0
        for c in line {
            if c == " " { count += 1 }
            else { break }
        }
        return count
    }

    private static func findKeyValueColon(in trimmed: String) -> String.Index? {
        // Find colon that's not inside quotes
        var inQuotes = false
        var quoteChar: Character?
        for (i, c) in trimmed.enumerated() {
            if (c == "\"" || c == "'") && (i == 0 || trimmed[trimmed.index(trimmed.startIndex, offsetBy: i - 1)] != "\\") {
                if !inQuotes {
                    inQuotes = true
                    quoteChar = c
                } else if c == quoteChar {
                    inQuotes = false
                    quoteChar = nil
                }
            }
            if c == ":" && !inQuotes {
                // Must have space after or be at end
                let afterIdx = trimmed.index(after: trimmed.index(trimmed.startIndex, offsetBy: i))
                if afterIdx == trimmed.endIndex || trimmed[afterIdx] == " " {
                    return trimmed.index(trimmed.startIndex, offsetBy: i)
                }
            }
        }
        return nil
    }

    private static func parseScalar(_ value: String) -> Any {
        let s = value.trimmingCharacters(in: .whitespaces)
        // Remove surrounding quotes
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            let unquoted = String(s.dropFirst().dropLast())
            return unquoted
        }
        // Boolean
        if s == "true" { return true }
        if s == "false" { return false }
        // Null
        if s == "null" || s == "~" { return NSNull() }
        // Integer
        if let int = Int(s) { return int }
        // Double
        if let double = Double(s) { return double }
        return s
    }
}

// MARK: - Minimal YAML Serializer

/// Serializes `[String: Any]` to YAML format, with sorted keys.
/// Matches anarlog's `serde_yaml` + `sort_value` output exactly.
private enum MinimalYAMLSerializer {
    static func serialize(_ value: Any, indent: Int = 0) -> String {
        serializeValue(value, indent: indent)
    }

    private static func serializeValue(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)

        switch value {
        case let dict as [String: Any]:
            if dict.isEmpty { return "" }
            let sortedKeys = dict.keys.sorted()
            var result = ""
            for key in sortedKeys {
                let val = dict[key]!
                let keyLine = "\(pad)\(key):"
                if let nestedDict = val as? [String: Any] {
                    if nestedDict.isEmpty {
                        result += "\(keyLine)\n"
                    } else {
                        result += "\(keyLine)\n"
                        result += serializeValue(nestedDict, indent: indent + 2)
                    }
                } else if let nestedArr = val as? [Any] {
                    if nestedArr.isEmpty {
                        result += "\(keyLine) []\n"
                    } else {
                        result += "\(keyLine)\n"
                        result += serializeValue(nestedArr, indent: indent)
                    }
                } else {
                    let scalarStr = serializeScalar(val)
                    result += "\(keyLine) \(scalarStr)\n"
                }
            }
            return result

        case let arr as [Any]:
            var result = ""
            for item in arr {
                if let dict = item as? [String: Any] {
                    // First key-value pair on same line as dash
                    let sortedKeys = dict.keys.sorted()
                    if let firstKey = sortedKeys.first {
                        let firstVal = dict[firstKey]!
                        result += "\(pad)- \(firstKey): \(serializeScalar(firstVal))\n"
                        let rest = dict.filter { $0.key != firstKey }
                        if !rest.isEmpty {
                            let restDict = Dictionary(uniqueKeysWithValues: rest.map { ($0.key, $0.value) })
                            result += serializeValue(restDict, indent: indent + 2)
                        }
                    } else {
                        result += "\(pad)- {}\n"
                    }
                } else if let nestedArr = item as? [Any] {
                    let nested = serializeValue(nestedArr, indent: indent + 2)
                    result += "\(pad)- \n\(nested)"
                } else {
                    result += "\(pad)- \(serializeScalar(item))\n"
                }
            }
            return result

        default:
            return "\(pad)\(serializeScalar(value))\n"
        }
    }

    private static func serializeScalar(_ value: Any) -> String {
        switch value {
        case let s as String:
            // Quote if string contains special YAML characters
            if s.isEmpty || s.contains(":") || s.contains("#") || s.contains("{") ||
               s.contains("}") || s.contains("[") || s.contains("]") ||
               s.contains("&") || s.contains("*") || s.contains("!") ||
               s.contains("|") || s.contains(">") || s.contains("%") ||
               s.contains("@") || s.contains("`") || s.contains(",") ||
               s.hasPrefix(" ") || s.hasSuffix(" ") ||
               s == "true" || s == "false" || s == "null" || s == "~" {
                return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return s
        case let n as NSNumber:
            // Check if it's a boolean
            if n === NSNumber(value: true) { return "true" }
            if n === NSNumber(value: false) { return "false" }
            // Check if it's an integer
            let d = n.doubleValue
            if d == floor(d) && d.isFinite {
                return String(format: "%.0f", d)
            }
            return "\(n)"
        case let b as Bool:
            return b ? "true" : "false"
        case is NSNull:
            return ""
        case let i as Int:
            return "\(i)"
        case let d as Double:
            if d == floor(d) && d.isFinite { return "\(Int(d))" }
            return "\(d)"
        default:
            return "\(value)"
        }
    }
}
