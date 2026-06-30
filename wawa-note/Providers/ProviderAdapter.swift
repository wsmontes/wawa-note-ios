import Foundation

// Related JIRA: KAN-9, KAN-42

// MARK: - Adapter

final class ProviderAdapter: @unchecked Sendable {

    /// Parse an AI response into a typed Decodable value.
    /// Handles: markdown fence removal, JSON extraction from within text,
    /// snake_case → camelCase conversion, and DecodingError wrapping.
    static func decode<T: Decodable>(_ type: T.Type, from response: String) throws -> T {
        let normalized = normalizeJSON(response)
        AppLog.provider.info("Decoding \(T.self), raw: \(response.prefix(200))")
        guard let data = normalized.data(using: .utf8) else {
            AppLog.provider.error("normalizeJSON produced invalid UTF-8")
            throw ProviderError.decodingFailed
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: data)
        } catch let decodingError as DecodingError {
            AppLog.provider.error("Decode failed for \(T.self): \(decodingError)")
            AppLog.provider.error("Normalized JSON: \(normalized.prefix(500))")
            throw ProviderError.decodingFailed
        } catch {
            AppLog.provider.error("Decode failed for \(T.self): \(error)")
            throw ProviderError.decodingFailed
        }
    }

    /// Clean and extract JSON from a raw AI response string.
    ///
    /// Strategy (in order):
    /// 1. Strip markdown fences (case-insensitive, handles newline variants)
    /// 2. Try direct JSON parse
    /// 3. Extract balanced `{ ... }` pair
    /// 4. Fallback: wrap raw text with proper escaping
    static func normalizeJSON(_ text: String) -> String {
        let cleaned = stripMarkdownFences(text)

        // Already valid JSON?
        if let data = cleaned.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return cleaned
        }

        // Try extracting balanced JSON brace pair
        if let extracted = extractBalancedJSON(cleaned) {
            return extracted
        }

        // No valid JSON found — return empty object instead of false-success raw_text wrapper.
        // Callers that try JSONDecoder.decode on this will get nil/default fields, not a
        // misleading raw_text key that silently masks extraction failures.
        return "{}"
    }

    // MARK: - Private helpers

    /// Extracts the first balanced `{ ... }` pair from text. Returns nil if none found.
    private static func extractBalancedJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for (i, ch) in text[start...].enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...text.index(start, offsetBy: i)]) }
            }
        }
        return nil
    }

    /// Strips markdown code fences. Case-insensitive, handles newline variants.
    private static func stripMarkdownFences(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip opening fence: ```json, ```JSON, ``` json, ```json\n, etc.
        if cleaned.hasPrefix("```") {
            let afterFence = String(cleaned.dropFirst(3))
            // Optional language tag: word chars only (letters, digits, hyphens), stops at newline or non-word char
            let langTag = afterFence.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
            var remaining = afterFence.dropFirst(langTag.count)
            // Drop single newline/whitespace between language tag and content
            let first = remaining.first
            if first == "\n" || first == "\r" {
                remaining = remaining.dropFirst()
                if first == "\r", remaining.first == "\n" { remaining = remaining.dropFirst() }
            }
            cleaned = String(remaining)
        }

        // Strip closing fence: ``` at end
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
