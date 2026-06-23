import Foundation
import UniformTypeIdentifiers
// Related JIRA: KAN-12, KAN-62


final class ICSImporter: FormatImporter, @unchecked Sendable {
    let formatIdentifier = "ics"
    let displayName = "Calendar Event"
    let supportedUTTypes: [UTType] = [.data]

    func canRead(url: URL) -> Bool {
        url.pathExtension.lowercased() == "ics"
    }

    func canRead(data: Data) -> Bool {
        if let str = String(data: data.prefix(1024), encoding: .utf8) {
            return str.contains("BEGIN:VCALENDAR")
        }
        return false
    }

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let text = try await Task.detached { try String(contentsOf: url, encoding: .utf8) }.value
        var warnings: [String] = []

        var title = url.deletingPathExtension().lastPathComponent
        var startDate = Date()
        var duration: Double?
        var eventUID: String?
        var location: String?
        var description: String?

        // Unfold folded lines (RFC 5545: CRLF followed by whitespace = continuation)
        var unfolded: [String] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if let first = line.first, first.isWhitespace, !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += line
            } else {
                unfolded.append(line)
            }
        }

        for line in unfolded {
            let trimmed = String(line)
            // Use first colon to split property name from value, supporting
            // ICS KEY parameters (e.g. "SUMMARY;LANGUAGE=en:Hello")
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let propName = String(trimmed[..<colonIdx])
            // Strip any parameters (semicolon and everything after)
            let baseProp = propName.components(separatedBy: ";").first ?? propName
            let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            switch baseProp {
            case "SUMMARY": title = value
            case "UID": eventUID = value
            case "LOCATION": location = value
            case "DESCRIPTION": description = value
            case "DTSTART":
                startDate = parseICSDate(value) ?? Date()
            case "DTEND":
                if let endDate = parseICSDate(value) {
                    duration = endDate.timeIntervalSince(startDate)
                }
            default: break
            }
        }

        // Build bodyText so the pipeline has content to analyze
        var bodyParts: [String] = []
        if let loc = location, !loc.isEmpty { bodyParts.append("Location: \(loc)") }
        if let dur = duration { bodyParts.append("Duration: \(Int(dur/60)) minutes") }
        if let desc = description, !desc.isEmpty { bodyParts.append(desc) }
        let bodyText = bodyParts.isEmpty ? nil : bodyParts.joined(separator: "\n\n")

        let item = KnowledgeItem(type: .audio, title: title, createdAt: startDate, status: .recorded, durationSeconds: duration)
        item.bodyText = bodyText
        item.scheduledDate = startDate
        if let uid = eventUID { item.calendarEventIdentifier = uid }
        item.isImported = true
        item.importSourceURL = url.absoluteString

        return ImportResult(knowledgeItem: item, artifacts: [:], warnings: warnings)
    }

    private func parseICSDate(_ str: String) -> Date? {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        // Try multiple ICS date formats: UTC (Z suffix), local, date-only
        let formats = [
            "yyyyMMdd'T'HHmmss'Z'",     // 20240101T120000Z
            "yyyyMMdd'T'HHmmss",         // 20240101T120000
            "yyyyMMdd",                   // 20240101 (date-only)
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            formatter.dateFormat = fmt
            formatter.timeZone = fmt.hasSuffix("'Z'") ? TimeZone(secondsFromGMT: 0) : .current
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
