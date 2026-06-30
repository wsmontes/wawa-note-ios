import Foundation

// Related JIRA: KAN-151

struct CapturedAnnotation: Sendable {
    let source: String
    let key: String
    let value: String
    let confidence: Double?

    init(source: String, key: String, value: String, confidence: Double? = nil) {
        self.source = source
        self.key = key
        self.value = value
        self.confidence = confidence
    }
}

/// Protocol for sensors that capture real-world context at the moment of recording.
///
/// Each sensor produces `CapturedAnnotation` values (source, key, value, confidence)
/// that are stamped onto a `KnowledgeItem` at capture time. The `ContextCaptureService`
/// orchestrates all sensors in parallel with a 10-second timeout.
///
/// ## Implementations (6)
/// - `CalendarContextSensor` — current calendar event title
/// - `AudioRouteSensor` — input port type and name
/// - `LocationContextSensor` — place name, latitude/longitude
/// - `BatterySensor` — battery level percentage
/// - `MotionActivitySensor` — motion activity type (walking, driving, etc.)
/// - `FocusModeSensor` — whether Focus/Do Not Disturb is active
///
/// ## Related Docs
/// - `docs/USER_JOURNEYS.md` — context capture during recording
protocol ContextSensor: Sendable {
    /// Human-readable name for logging and debugging.
    var sensorName: String { get }
    /// Capture current context. Returns annotations on success, throws on failure.
    /// Failures from individual sensors are logged but do not block recording.
    func capture() async throws -> [CapturedAnnotation]
}
