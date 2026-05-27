import Foundation

final class ContextCaptureService: @unchecked Sendable {
    private let sensors: [any ContextSensor]

    init(sensors: [any ContextSensor] = ContextCaptureService.defaultSensors()) {
        self.sensors = sensors
    }

    static func defaultSensors() -> [any ContextSensor] {
        [CalendarContextSensor(), AudioRouteSensor(), LocationContextSensor(), BatterySensor()]
    }

    func captureAll() async -> [CapturedAnnotation] {
        await withTaskGroup(of: [CapturedAnnotation].self) { group in
            for sensor in sensors {
                group.addTask {
                    (try? await sensor.capture()) ?? []
                }
            }
            var all: [CapturedAnnotation] = []
            for await result in group { all.append(contentsOf: result) }
            return all
        }
    }
}
