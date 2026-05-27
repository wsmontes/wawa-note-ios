import Foundation

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

protocol ContextSensor: Sendable {
    var sensorName: String { get }
    func capture() async throws -> [CapturedAnnotation]
}

