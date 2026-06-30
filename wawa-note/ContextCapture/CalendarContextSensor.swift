import EventKit
import Foundation
import OSLog

// Related JIRA: KAN-151

final class CalendarContextSensor: ContextSensor, @unchecked Sendable {
    let sensorName = "calendar_context"

    private let eventStore: EKEventStore

    private static let contextWindowBefore: TimeInterval = -900  // 15 minutes
    private static let contextWindowAfter: TimeInterval = 10800  // 3 hours
    private static let proximityThreshold: TimeInterval = 300  // 5 minutes

    init(eventStore: EKEventStore = .shared) {
        self.eventStore = eventStore
    }

    func capture() async throws -> [CapturedAnnotation] {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .authorized || status == .fullAccess else {
            AppLog.general.info("CalendarContextSensor: not authorized")
            return []
        }

        let now = Date()
        let windowStart = now.addingTimeInterval(Self.contextWindowBefore)
        let windowEnd = now.addingTimeInterval(Self.contextWindowAfter)

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        var annotations: [CapturedAnnotation] = []

        for event in events {
            let title = event.title ?? ""
            if event.startDate <= now && event.endDate >= now {
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_proximity", value: "during"))
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_title", value: title))
                if let location = event.location, !location.isEmpty {
                    annotations.append(CapturedAnnotation(source: sensorName, key: "event_location", value: location))
                }
            } else if now < event.startDate && event.startDate.timeIntervalSince(now) < Self.proximityThreshold {
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_proximity", value: "before"))
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_title", value: title))
            } else if now > event.endDate && now.timeIntervalSince(event.endDate) < Self.proximityThreshold {
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_proximity", value: "after"))
                annotations.append(CapturedAnnotation(source: sensorName, key: "event_title", value: title))
            }
        }

        return annotations
    }
}
