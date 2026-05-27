import Foundation
import EventKit

enum EventSource {
    case wawaNote(MeetingModel)
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

    var meeting: MeetingModel? {
        if case .wawaNote(let m) = source { return m }
        return nil
    }

    var isFromWawaNote: Bool {
        if case .wawaNote = source { return true }
        return false
    }

    init(meeting: MeetingModel) {
        self.id = meeting.id.uuidString
        self.title = meeting.title.isEmpty ? "Untitled" : meeting.title
        self.startDate = meeting.scheduledDate ?? meeting.createdAt
        self.endDate = meeting.scheduledDate.map { $0.addingTimeInterval(meeting.durationSeconds ?? 0) }
            ?? meeting.createdAt.addingTimeInterval(meeting.durationSeconds ?? 0)
        self.isAllDay = false
        self.source = .wawaNote(meeting)
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
