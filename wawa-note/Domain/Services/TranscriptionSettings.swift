import Foundation
// Related JIRA: KAN-6


enum TranscriptionMode: String {
    case apple = "apple"
    case whisper = "whisper"

    var label: String {
        switch self {
        case .apple: "Apple Speech (on-device)"
        case .whisper: "Whisper via API"
        }
    }
}

final class TranscriptionSettings: @unchecked Sendable {
    nonisolated(unsafe) static let shared = TranscriptionSettings()
    private let defaults = UserDefaults.standard
    private let key = "transcription_mode"

    var mode: TranscriptionMode {
        get {
            guard let raw = defaults.string(forKey: key),
                  let mode = TranscriptionMode(rawValue: raw) else {
                return .apple
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }

    var useRemoteWhisper: Bool {
        mode == .whisper
    }
}
