import Foundation

enum WatchCommand: String, Codable {
    case startRecording
    case pauseRecording
    case resumeRecording
    case stopRecording
    case requestStatus
}

struct RecordingStatus: Codable, Equatable {
    let state: String
    let elapsedTime: Double
    let audioLevel: Float
    let errorMessage: String?
    let meetingTitle: String?
    let isActive: Bool

    static func idle() -> RecordingStatus {
        RecordingStatus(
            state: "idle", elapsedTime: 0, audioLevel: 0,
            errorMessage: nil, meetingTitle: nil, isActive: false
        )
    }
}
