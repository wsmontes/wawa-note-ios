import Foundation
import EventKit

enum EventSource {
    case wawaNote(KnowledgeItem)
    case iphoneCalendar
}

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let source: EventSource
    let location: String?
    let notes: String?
    let attendees: [String]?

    var item: KnowledgeItem? {
        if case .wawaNote(let i) = source { return i }
        return nil
    }

    var isFromWawaNote: Bool {
        if case .wawaNote = source { return true }
        return false
    }

    init(item: KnowledgeItem) {
        self.id = item.id.uuidString
        self.title = item.title.isEmpty ? "Untitled" : item.title
        self.startDate = item.scheduledDate ?? item.createdAt
        self.endDate = item.scheduledDate.map { $0.addingTimeInterval(item.durationSeconds ?? 0) }
            ?? item.createdAt.addingTimeInterval(item.durationSeconds ?? 0)
        self.isAllDay = false
        self.source = .wawaNote(item)
        self.location = nil
        self.notes = nil
        self.attendees = nil
    }

    init(ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier ?? UUID().uuidString
        self.title = ekEvent.title ?? "Untitled"
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.isAllDay = ekEvent.isAllDay
        self.source = .iphoneCalendar
        self.location = ekEvent.location
        self.notes = ekEvent.notes
        self.attendees = ekEvent.attendees?.compactMap { $0.name ?? $0.url.absoluteString }
    }

    var durationMinutes: Int {
        guard !isAllDay else { return 0 }
        let interval = endDate.timeIntervalSince(startDate)
        return max(0, Int(interval / 60))
    }
}
