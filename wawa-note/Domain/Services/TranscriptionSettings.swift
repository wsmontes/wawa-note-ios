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
                let mode = TranscriptionMode(rawValue: raw)
            else {
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

    /// Whether the user allows Apple's cloud transcription fallback (KAN-476).
    /// Defaults to true (cloud allowed) — on-device recognition on iOS 18.x
    /// can return empty segments for short audio, making transcripts invisible.
    var allowCloud: Bool {
        get {
            // Default to true: cloud transcription is more reliable for short audio.
            // UserDefaults.bool(forKey:) returns false for missing keys, which would
            // force on-device-only and cause "No speech detected" for valid audio.
            if defaults.object(forKey: "transcription_allow_cloud") == nil {
                return true
            }
            return defaults.bool(forKey: "transcription_allow_cloud")
        }
        set { defaults.set(newValue, forKey: "transcription_allow_cloud") }
    }
}
