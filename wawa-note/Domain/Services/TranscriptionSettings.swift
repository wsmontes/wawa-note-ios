import Foundation

// Related JIRA: KAN-538

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

// SAFETY: UserDefaults-based settings. All access serialized via property wrapper.
final class TranscriptionSettings: @unchecked Sendable {
  static let shared = TranscriptionSettings()
  private let defaults = UserDefaults.standard
  private let modeKey = "transcription_mode"
  private let vadKey = "transcription_vad_prefilter"

  var mode: TranscriptionMode {
    get {
      guard let raw = defaults.string(forKey: modeKey),
        let mode = TranscriptionMode(rawValue: raw)
      else {
        return .apple
      }
      return mode
    }
    set {
      defaults.set(newValue.rawValue, forKey: modeKey)
    }
  }

  var useRemoteWhisper: Bool {
    mode == .whisper
  }

  /// When enabled, Voice Activity Detection removes silent portions from audio
  /// before sending to the transcription engine. Reduces Whisper hallucination
  /// on silent audio. Default: true.
  var useVADPreFilter: Bool {
    get {
      if defaults.object(forKey: vadKey) == nil { return true }
      return defaults.bool(forKey: vadKey)
    }
    set {
      defaults.set(newValue, forKey: vadKey)
    }
  }
}
