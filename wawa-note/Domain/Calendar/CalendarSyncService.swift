import EventKit
import OSLog
import Foundation

@MainActor
final class CalendarSyncService: ObservableObject {
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var selectedCalendarIDs: Set<String> = []

    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
        self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            authorizationStatus = granted ? .fullAccess : .denied
            return granted
        } catch {
            AppLog.general.error("Calendar permission request failed: \(error.localizedDescription)")
            authorizationStatus = .denied
            return false
        }
    }

    var hasPermission: Bool {
        authorizationStatus == .fullAccess
    }

    // MARK: - Calendars

    func fetchCalendars() -> [EKCalendar] {
        guard hasPermission else { return [] }
        return eventStore.calendars(for: .event).filter { $0.allowsContentModifications || true }
    }

    // MARK: - Fetch events

    func fetchEvents(for dateInterval: DateInterval) -> [EKEvent] {
        guard hasPermission else { return [] }
        let predicate = eventStore.predicateForEvents(
            withStart: dateInterval.start,
            end: dateInterval.end,
            calendars: nil
        )
        return eventStore.events(matching: predicate)
    }

    func fetchEvents(for date: Date) -> [EKEvent] {
        let startOfDay = Calendar.current.startOfDay(for: date)
        guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        return fetchEvents(for: DateInterval(start: startOfDay, end: endOfDay))
    }

    // MARK: - Month events (for dot indicators)

    func eventDatesForMonth(containing date: Date, meetings: [MeetingModel]) -> Set<Date> {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date)),
              let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: date)),
              let lastOfMonth = cal.date(byAdding: DateComponents(month: 1, day: -1), to: firstOfMonth) else {
            return []
        }

        var dates: Set<Date> = []
        let monthInterval = DateInterval(start: firstOfMonth, end: lastOfMonth)

        // Wawa Note meetings
        for meeting in meetings {
            let meetingDate = meeting.scheduledDate ?? meeting.createdAt
            if monthInterval.contains(meetingDate) {
                dates.insert(cal.startOfDay(for: meetingDate))
            }
        }

        // iPhone calendar events
        if hasPermission {
            let ekEvents = fetchEvents(for: monthInterval)
            for event in ekEvents {
                if monthInterval.contains(event.startDate) {
                    dates.insert(cal.startOfDay(for: event.startDate))
                }
            }
        }

        return dates
    }

    // MARK: - Unified events for a day

    func unifiedEvents(for date: Date, meetings: [MeetingModel]) -> [CalendarEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        var events: [CalendarEvent] = []

        // Wawa Note meetings that fall on this day
        for meeting in meetings {
            let meetingDate = meeting.scheduledDate ?? meeting.createdAt
            if meetingDate >= dayStart && meetingDate < dayEnd {
                events.append(CalendarEvent(meeting: meeting))
            }
        }

        // iPhone calendar events
        if hasPermission {
            let ekEvents = fetchEvents(for: DateInterval(start: dayStart, end: dayEnd))
            for ekEvent in ekEvents {
                // Avoid duplicate with Wawa Note meetings (linked by calendarEventIdentifier)
                if let calID = ekEvent.eventIdentifier,
                   meetings.contains(where: { $0.calendarEventIdentifier == calID }) {
                    continue
                }
                events.append(CalendarEvent(ekEvent: ekEvent))
            }
        }

        return events.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Single EKEvent lookup

    func ekEvent(with identifier: String) -> EKEvent? {
        guard hasPermission else { return nil }
        return eventStore.event(withIdentifier: identifier)
    }
}
