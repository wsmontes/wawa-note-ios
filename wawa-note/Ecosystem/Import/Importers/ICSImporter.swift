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
      if trimmed.hasPrefix("SUMMARY:") {
        title = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
      }
      if trimmed.hasPrefix("UID:") {
        eventUID = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
      }
      if trimmed.hasPrefix("LOCATION:") {
        location = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
      }
      if trimmed.hasPrefix("DESCRIPTION:") {
        description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
      }
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

    // Build bodyText so the pipeline has content to analyze
    var bodyParts: [String] = []
    if let loc = location, !loc.isEmpty { bodyParts.append("Location: \(loc)") }
    if let dur = duration { bodyParts.append("Duration: \(Int(dur/60)) minutes") }
    if let desc = description, !desc.isEmpty { bodyParts.append(desc) }
    let bodyText = bodyParts.isEmpty ? nil : bodyParts.joined(separator: "\n\n")

    let item = KnowledgeItem(
      type: .audio, title: title, createdAt: startDate, status: .recorded, durationSeconds: duration
    )
    item.bodyText = bodyText
    item.scheduledDate = startDate
    if let uid = eventUID { item.calendarEventIdentifier = uid }
    item.isImported = true
    item.importSourceURL = url.absoluteString

    return ImportResult(knowledgeItem: item, artifacts: [:], warnings: warnings)
  }

  private func parseICSDate(_ str: String) -> Date? {
    let cleaned = str.replacingOccurrences(of: "T", with: "").replacingOccurrences(
      of: "Z", with: "")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: cleaned)
  }
}
