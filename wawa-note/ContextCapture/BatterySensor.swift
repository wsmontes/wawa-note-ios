import Foundation
import UIKit

final class BatterySensor: ContextSensor, @unchecked Sendable {
  let sensorName = "battery_state"

  func capture() async throws -> [CapturedAnnotation] {
    let (level, state): (Float, UIDevice.BatteryState) = await MainActor.run {
      UIDevice.current.isBatteryMonitoringEnabled = true
      return (UIDevice.current.batteryLevel, UIDevice.current.batteryState)
    }

    var annotations: [CapturedAnnotation] = []

    if level >= 0 {
      annotations.append(
        CapturedAnnotation(
          source: sensorName, key: "level", value: String(format: "%.0f", level * 100)))
    }

    let stateStr: String = {
      switch state {
      case .unknown: return "unknown"
      case .unplugged: return "unplugged"
      case .charging: return "charging"
      case .full: return "full"
      @unknown default: return "unknown"
      }
    }()
    annotations.append(CapturedAnnotation(source: sensorName, key: "state", value: stateStr))

    return annotations
  }
}
