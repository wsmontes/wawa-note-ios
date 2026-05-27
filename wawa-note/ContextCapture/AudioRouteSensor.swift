import AVFoundation
import Foundation

final class AudioRouteSensor: ContextSensor, @unchecked Sendable {
    let sensorName = "audio_route"

    func capture() async throws -> [CapturedAnnotation] {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs

        var annotations: [CapturedAnnotation] = []

        for output in outputs {
            annotations.append(CapturedAnnotation(source: sensorName, key: "route_type", value: output.portType.rawValue))
            annotations.append(CapturedAnnotation(source: sensorName, key: "route_name", value: output.portName))
        }

        if outputs.isEmpty {
            annotations.append(CapturedAnnotation(source: sensorName, key: "route_type", value: "none"))
        }

        return annotations
    }
}
