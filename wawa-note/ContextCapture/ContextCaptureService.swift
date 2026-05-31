import Foundation
import OSLog

final class ContextCaptureService: @unchecked Sendable {
    private let sensors: [any ContextSensor]

    private static let sensorTimeoutSeconds: UInt64 = 10_000_000_000

    init(sensors: [any ContextSensor] = ContextCaptureService.defaultSensors()) {
        self.sensors = sensors
    }

    static func defaultSensors() -> [any ContextSensor] {
        [
            CalendarContextSensor(),
            AudioRouteSensor(),
            LocationContextSensor(),
            BatterySensor(),
            MotionActivitySensor(),
            FocusModeSensor()
        ]
    }

    func captureAll() async -> [CapturedAnnotation] {
        await withTaskGroup(of: [CapturedAnnotation].self) { group in
            for sensor in sensors {
                group.addTask {
                    await withTaskGroup(of: [CapturedAnnotation].self) { inner in
                        inner.addTask {
                            (try? await sensor.capture()) ?? []
                        }
                        inner.addTask {
                            try? await Task.sleep(nanoseconds: Self.sensorTimeoutSeconds)
                            return []
                        }
                        let result = await inner.next()
                        inner.cancelAll()
                        return result ?? []
                    }
                }
            }
            var all: [CapturedAnnotation] = []
            for await result in group {
                all.append(contentsOf: result)
            }
            return all
        }
    }
}
