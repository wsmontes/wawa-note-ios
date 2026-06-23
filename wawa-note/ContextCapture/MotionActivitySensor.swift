import CoreMotion
import Foundation
import OSLog
// Related JIRA: KAN-151


final class MotionActivitySensor: ContextSensor, @unchecked Sendable {
    let sensorName = "motion_activity"

    private static let timeoutSeconds: TimeInterval = 5

    func capture() async throws -> [CapturedAnnotation] {
        guard CMMotionActivityManager.isActivityAvailable() else {
            AppLog.general.info("MotionActivitySensor: not available")
            return []
        }

        guard Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil else {
            AppLog.general.warning("MotionActivitySensor: NSMotionUsageDescription missing from Info.plist — skipping")
            return []
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CapturedAnnotation], Error>) in
            let manager = CMMotionActivityManager()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1

            let lock = OSAllocatedUnfairLock()
            var resumed = false

            // Timeout after 5s
            let timeoutWork = DispatchWorkItem {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                manager.stopActivityUpdates()
                queue.cancelAllOperations()
                continuation.resume(returning: [])
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: timeoutWork)

            manager.startActivityUpdates(to: queue) { activity in
                lock.lock()
                guard let activity, !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                timeoutWork.cancel()
                manager.stopActivityUpdates()
                queue.cancelAllOperations()

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
        }
    }
}
