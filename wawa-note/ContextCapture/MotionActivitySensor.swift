import CoreMotion
import Foundation
import OSLog

final class MotionActivitySensor: ContextSensor, @unchecked Sendable {
    let sensorName = "motion_activity"

    func capture() async throws -> [CapturedAnnotation] {
        guard CMMotionActivityManager.isActivityAvailable() else {
            AppLog.general.info("MotionActivitySensor: not available")
            return []
        }

        // Safety check: verify plist key exists to prevent SIGKILL
        guard Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil else {
            AppLog.general.warning("MotionActivitySensor: NSMotionUsageDescription missing from Info.plist — skipping")
            return []
        }

        let manager = CMMotionActivityManager()

        return await withCheckedContinuation { continuation in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1

            manager.startActivityUpdates(to: queue) { activity in
                guard let activity else { return }
                manager.stopActivityUpdates()

                var annotations: [CapturedAnnotation] = []
                if activity.stationary { annotations.append(CapturedAnnotation(source: "motion_activity", key: "activity", value: "stationary")) }
                if activity.walking { annotations.append(CapturedAnnotation(source: "motion_activity", key: "activity", value: "walking")) }
                if activity.running { annotations.append(CapturedAnnotation(source: "motion_activity", key: "activity", value: "running")) }
                if activity.automotive { annotations.append(CapturedAnnotation(source: "motion_activity", key: "activity", value: "automotive")) }
                if activity.cycling { annotations.append(CapturedAnnotation(source: "motion_activity", key: "activity", value: "cycling")) }
                if activity.unknown { annotations.append(CapturedAnnotation(source: "motion_activity", key: "activity", value: "unknown")) }

                let conf: String = {
                    switch activity.confidence {
                    case .low: return "low"
                    case .medium: return "medium"
                    case .high: return "high"
                    @unknown default: return "unknown"
                    }
                }()
                annotations.append(CapturedAnnotation(source: "motion_activity", key: "confidence", value: conf))

                continuation.resume(returning: annotations)
            }

            // Timeout after 5s
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                manager.stopActivityUpdates()
                continuation.resume(returning: [])
            }
        }
    }
}
