import Foundation
import Intents
import OSLog

final class FocusModeSensor: ContextSensor, @unchecked Sendable {
    let sensorName = "focus_mode"

    func capture() async throws -> [CapturedAnnotation] {
        let status = INFocusStatusCenter.default.focusStatus

        var annotations: [CapturedAnnotation] = []
        annotations.append(CapturedAnnotation(
            source: sensorName,
            key: "focus_active",
            value: status.isFocused == true ? "true" : "false"
        ))

        return annotations
    }
}
