import EventKit
import Foundation
import OSLog
import SwiftData

extension EKEventStore {
  nonisolated(unsafe) static let shared = EKEventStore()
}

@MainActor
final class CalendarSyncService: ObservableObject {
  @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined

  private let eventStore: EKEventStore

  private static let eventMatchTolerance: TimeInterval = 60

  init(eventStore: EKEventStore = .shared) {
    self.eventStore = eventStore
    self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    observeEventStoreChanges()
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
    let status = EKEventStore.authorizationStatus(for: .event)
    return status == .fullAccess || status == .authorized
  }

  // MARK: - Reactive updates

  private func observeEventStoreChanges() {
    NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged,
      object: eventStore,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.objectWillChange.send()
        self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
      }
    }
  }

  // MARK: - Calendars

  func fetchCalendars() -> [EKCalendar] {
    guard hasPermission else { return [] }
    return eventStore.calendars(for: .event)
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

  // MARK: - Month summaries (for day cell dots)

  func eventDatesForMonth(containing date: Date, items: [KnowledgeItem]) -> Set<Date> {
    let cal = Calendar.current
    guard let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: date)),
      let firstOfNext = cal.date(byAdding: DateComponents(month: 1), to: firstOfMonth)
    else {
      return []
    }

    var dates: Set<Date> = []
    let monthInterval = DateInterval(start: firstOfMonth, end: firstOfNext)

    for item in items {
      let itemDate = item.scheduledDate ?? item.createdAt
      if monthInterval.contains(itemDate) {
        dates.insert(cal.startOfDay(for: itemDate))
      }
    }

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

  func unifiedEvents(for date: Date, items: [KnowledgeItem]) -> [CalendarEvent] {
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: date)
    guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

    var events: [CalendarEvent] = []

    for item in items {
      let itemDate = item.scheduledDate ?? item.createdAt
      if itemDate >= dayStart && itemDate < dayEnd {
        events.append(CalendarEvent(item: item))
      }
    }

    if hasPermission {
      let ekEvents = fetchEvents(for: DateInterval(start: dayStart, end: dayEnd))
      for ekEvent in ekEvents {
        if isAlreadyRepresented(ekEvent: ekEvent, items: items) {
          continue
        }
        events.append(CalendarEvent(ekEvent: ekEvent))
      }
    }

    return events.sorted { $0.startDate < $1.startDate }
  }

  private func isAlreadyRepresented(ekEvent: EKEvent, items: [KnowledgeItem]) -> Bool {
    // Match by calendarEventIdentifier
    if let calID = ekEvent.eventIdentifier,
      items.contains(where: { $0.calendarEventIdentifier == calID })
    {
      return true
    }
    // Fallback: match by scheduledDate + title
    guard let eventStart = ekEvent.startDate else { return false }
    let eventTitle = ekEvent.title ?? ""
    return items.contains { item in
      guard let itemSD = item.scheduledDate else { return false }
      return abs(itemSD.timeIntervalSince(eventStart)) < Self.eventMatchTolerance
        && item.title == eventTitle
    }
  }

  // MARK: - Single EKEvent lookup

  func ekEvent(with identifier: String) -> EKEvent? {
    guard hasPermission else { return nil }
    return eventStore.event(withIdentifier: identifier)
  }

  // MARK: - Create events

  func createEvent(title: String, startDate: Date, endDate: Date? = nil, notes: String? = nil)
    throws -> String
  {
    guard hasPermission else { throw CalendarError.permissionDenied }
    let event = EKEvent(eventStore: eventStore)
    event.title = title
    event.startDate = startDate
    event.endDate = endDate ?? startDate.addingTimeInterval(3600)
    event.notes = notes
    event.calendar =
      eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first
    try eventStore.save(event, span: .thisEvent, commit: true)
    return event.eventIdentifier
  }

  // MARK: - Anarlog participant bridge

  /// Extract anarlog-format participants from a calendar event.
  func anarlogParticipants(from event: EKEvent) -> [AnarlogParticipant] {
    AnarlogParticipantBridge.fromCalendarEvent(event)
  }

  /// Annotate a KnowledgeItem with participants from its linked calendar event.
  func annotateAnarlogParticipants(item: KnowledgeItem, context: ModelContext) {
    guard let eventId = item.calendarEventIdentifier,
      let event = eventStore.event(withIdentifier: eventId)
    else { return }
    let participants = anarlogParticipants(from: event)
    guard !participants.isEmpty else { return }
    AnarlogParticipantBridge.annotateParticipants(
      participants, itemID: item.id, source: "calendar_event", context: context)
  }
}

enum CalendarError: Error, LocalizedError {
  case permissionDenied
  var errorDescription: String? {
    "Calendar access is off. Enable in Settings > Privacy & Security > Calendars."
  }
}
