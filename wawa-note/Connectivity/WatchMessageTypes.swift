import Foundation
// Related JIRA: KAN-153


enum WatchCommand: String, Codable {
    case startRecording
    case pauseRecording
    case resumeRecording
    case stopRecording
    case requestStatus
}

enum WatchMessageKey {
    static let type = "type"
    static let command = "command"
    static let state = "state"
    static let elapsedTime = "elapsedTime"
    static let audioLevel = "audioLevel"
    static let isActive = "isActive"
    static let recordingTitle = "recordingTitle"
    static let errorMessage = "errorMessage"
}

struct RecordingStatus: Codable, Equatable {
    let state: String
    let elapsedTime: Double
    let audioLevel: Float
    let errorMessage: String?
    let recordingTitle: String?
    let isActive: Bool

    static func idle() -> RecordingStatus {
        RecordingStatus(
            state: "idle", elapsedTime: 0, audioLevel: 0,
            errorMessage: nil, recordingTitle: nil, isActive: false
        )
    }
}
