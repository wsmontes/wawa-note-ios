import AVFoundation
import UIKit
import OSLog

enum AudioSessionError: Error {
    case configurationFailed
    case permissionDenied
    case diskFull
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
                .allowBluetooth,
                .defaultToSpeaker
            ])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            AppLog.error("audio", "Failed to configure audio session: \(error.localizedDescription)")
            throw AudioSessionError.configurationFailed
        }
    }

    func reconfigureForRecording() throws {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try configureForRecording()
    }

    func deactivate() throws {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLog.error("audio", "Failed to deactivate audio session: \(error.localizedDescription)")
            throw AudioSessionError.configurationFailed
        }
    }

    func hasMinimumDiskSpace(requiredBytes: Int64 = 50_000_000) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                return freeSize >= requiredBytes
            }
            return true // If we can't determine, don't block
        } catch {
            AppLog.audio.warning("Could not check disk space: \(error)")
            return true // Don't block on failure to check
        }
    }

    var isConfigured: Bool {
        session.category == .playAndRecord
    }

    var isInputAvailable: Bool {
        session.currentRoute.inputs.contains(where: { (port: AVAudioSessionPortDescription) -> Bool in
            (port.channels?.count ?? 0) > 0
        })
    }

    var sampleRate: Double {
        session.sampleRate
    }

    /// Human-readable name of the current audio input source.
    /// Returns "iPhone", "AirPods", "CarPlay", "Bluetooth Headset", etc.
    var currentInputPortName: String {
        guard let input = session.currentRoute.inputs.first else {
            return "No Microphone"
        }
        switch input.portType {
        case .builtInMic, .builtInReceiver:
            return UIDevice.current.model  // "iPhone", "iPad", etc.
        case .headsetMic, .headphones:
            return "Wired Headset"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return input.portName
        case .carAudio:
            return "CarPlay"
        case .usbAudio:
            return input.portName.isEmpty ? "USB Microphone" : input.portName
        default:
            return input.portName.isEmpty ? "External Microphone" : input.portName
        }
    }

    /// SF Symbol name for the current input source icon.
    var currentInputIcon: String {
        guard let input = session.currentRoute.inputs.first else {
            return "mic.slash"
        }
        switch input.portType {
        case .builtInMic, .builtInReceiver:
            return "iphone"
        case .headsetMic, .headphones:
            return "headphones"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return "airpodspro.chargingcase.wireless.fill"
        case .carAudio:
            return "car.fill"
        case .usbAudio:
            return "cable.connector"
        default:
            return "mic.fill"
        }
    }
}
