import AVFoundation
import OSLog

enum AudioSessionError: Error {
    case configurationFailed
    case permissionDenied
}

final class AudioSessionManager {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func configureForRecording() throws {
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [
                .allowBluetoothHFP,
                .defaultToSpeaker
            ])
            try session.setActive(true)
        } catch {
            AppLog.audio.error("Failed to configure audio session: \(error.localizedDescription)")
            throw AudioSessionError.configurationFailed
        }
    }

    func deactivate() throws {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLog.audio.error("Failed to deactivate audio session: \(error.localizedDescription)")
            throw AudioSessionError.configurationFailed
        }
    }

    var isConfigured: Bool {
        session.category == .playAndRecord
    }
}
