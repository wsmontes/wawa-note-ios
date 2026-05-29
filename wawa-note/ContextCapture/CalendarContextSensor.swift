import Foundation
import EventKit
import OSLog

final class CalendarContextSensor: ContextSensor, @unchecked Sendable {
    let sensorName = "calendar_context"

    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func capture() async throws -> [CapturedAnnotation] {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .authorized || status == .fullAccess else {
            AppLog.general.info("CalendarContextSensor: not authorized")
            return []
        }

        let now = Date()
        let windowStart = now.addingTimeInterval(-15 * 60)
        let windowEnd = now.addingTimeInterval(3 * 60 * 60)

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        var annotations: [CapturedAnnotation] = []

        for event in events {
            if event.startDate <= now && event.endDate >= now {
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_proximity", value: "during"))
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_title", value: event.title))
                if let location = event.location, !location.isEmpty {
                    annotations.append(CapturedAnnotation(source: sensorName, key: "event_location", value: location))
                }
            } else if now < event.startDate && event.startDate.timeIntervalSince(now) < 5 * 60 {
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_proximity", value: "before"))
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_title", value: event.title))
            } else if now > event.endDate && now.timeIntervalSince(event.endDate) < 5 * 60 {
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_proximity", value: "after"))
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_title", value: event.title))
            }
        }

        return annotations
    }
}
