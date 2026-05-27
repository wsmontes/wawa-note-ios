import Foundation
import UniformTypeIdentifiers

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
        let text = try String(contentsOf: url, encoding: .utf8)
        let warnings: [String] = []

        var title = url.deletingPathExtension().lastPathComponent
        var startDate = Date()
        var duration: Double?
        var eventUID: String?

        for line in text.split(separator: "\n") {
            let trimmed = String(line)
            if trimmed.hasPrefix("SUMMARY:") { title = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            if trimmed.hasPrefix("UID:") { eventUID = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            if trimmed.hasPrefix("DTSTART:") {
                let dateStr = String(trimmed.dropFirst(8))
                startDate = parseICSDate(dateStr) ?? Date()
            }
            if trimmed.hasPrefix("DTEND:") {
                let endStr = String(trimmed.dropFirst(6))
                if let endDate = parseICSDate(endStr) {
                    duration = endDate.timeIntervalSince(startDate)
                }
            }
        }

        let item = KnowledgeItem(type: .meeting, title: title, createdAt: startDate, status: .draft, durationSeconds: duration)
        item.scheduledDate = startDate
        if let uid = eventUID { item.calendarEventIdentifier = uid }

        return ImportResult(knowledgeItem: item, artifacts: [:], warnings: warnings)
    }

    private func parseICSDate(_ str: String) -> Date? {
        let cleaned = str.replacingOccurrences(of: "T", with: "").replacingOccurrences(of: "Z", with: "")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: cleaned)
    }
}
