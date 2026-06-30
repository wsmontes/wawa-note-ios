import EventKit
import Foundation

enum TimelineEntrySource {
    case wawaNote(KnowledgeItem)
    case iphoneCalendar(EKEvent)
}

struct TimelineEntry: Identifiable {
    let id: String
    let title: String
    let bodySnippet: String?
    let createdAt: Date
    let scheduledDate: Date?
    let source: TimelineEntrySource
    let contentType: KnowledgeItemType?
    let mood: String?
    let durationMinutes: Int?
    let isAllDay: Bool

    // MARK: - Init from KnowledgeItem

    init(item: KnowledgeItem) {
        self.id = item.id.uuidString
        self.title = item.title.isEmpty ? "Untitled" : item.title
        self.bodySnippet = item.bodyText.map { String($0.prefix(120)) }
        self.createdAt = item.createdAt
        self.scheduledDate = item.scheduledDate
        self.source = .wawaNote(item)
        self.contentType = item.type
        self.mood = Self.extractMood(from: item.tags)
        self.durationMinutes = item.durationSeconds.map { Int($0 / 60) }
        self.isAllDay = false
    }

    // MARK: - Init from EKEvent

    init(ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier ?? UUID().uuidString
        self.title = ekEvent.title
        self.bodySnippet = ekEvent.notes
        self.createdAt = ekEvent.startDate
        self.scheduledDate = ekEvent.startDate
        self.source = .iphoneCalendar(ekEvent)
        self.contentType = nil
        self.mood = nil
        self.durationMinutes =
            ekEvent.endDate.timeIntervalSince(ekEvent.startDate) > 0
            ? Int(ekEvent.endDate.timeIntervalSince(ekEvent.startDate) / 60)
            : nil
        self.isAllDay = ekEvent.isAllDay
    }

    // MARK: - Computed

    var isFromWawaNote: Bool {
        if case .wawaNote = source { return true }
        return false
    }

    var wawaItem: KnowledgeItem? {
        if case .wawaNote(let item) = source { return item }
        return nil
    }

    var typeIcon: String {
        contentType?.icon ?? "calendar"
    }

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: scheduledDate ?? createdAt)
    }

    // MARK: - Helpers

    static func extractMood(from tags: [String]) -> String? {
        tags.first { $0.hasPrefix("mood/") }
            .map { String($0.dropFirst(5)) }  // "mood/great" → "great"
    }
}
