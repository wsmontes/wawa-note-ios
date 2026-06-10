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

    /// User preference: .spokenAudio (enhanced, default) or .default (raw).
    static var useVoiceProcessing: Bool {
        get { !UserDefaults.standard.bool(forKey: "audio_raw_mode") }
        set { UserDefaults.standard.set(!newValue, forKey: "audio_raw_mode") }
    }

    /// Speakerphone / viva-voz mode: activates front mic array + beamforming.
    /// Uses .videoChat mode which engages the iPhone's multi-mic beamformer
    /// for far-field voice pickup — ideal when the phone is on a table.
    static var speakerphoneMode: Bool {
        get { UserDefaults.standard.bool(forKey: "audio_speakerphone_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "audio_speakerphone_mode") }
    }

    /// Whether the current audio route is CarPlay.
    var isCarPlayActive: Bool {
        session.currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// Whether the current input is a Bluetooth device without a microphone
    /// (A2DP profile only — music headphones, not headsets).
    var isBluetoothWithoutMic: Bool {
        let input = session.currentRoute.inputs.first
        guard let port = input else { return false }
        let isBT = port.portType == .bluetoothA2DP || port.portType == .bluetoothLE
        let hasChannels = (port.channels?.count ?? 0) > 0
        return isBT && !hasChannels
    }

    /// Best audio mode for the current route. Different devices need different modes:
    /// - CarPlay / USB → .default (most compatible)
    /// - Bluetooth HFP → .default (voice processing can cause issues)
    /// - Built-in mic → .spokenAudio (voice enhancement) or .videoChat (far-field)
    func bestModeForCurrentRoute() -> AVAudioSession.Mode {
        if isCarPlayActive { return .default }
        if isBluetoothWithoutMic { return .default }
        let input = session.currentRoute.inputs.first
        if input?.portType == .usbAudio { return .default }
        if input?.portType == .bluetoothHFP { return .default }
        if input?.portType == .headsetMic { return .default }
        // Built-in mic or AirPods with HFP
        if Self.speakerphoneMode { return .videoChat }
        return Self.useVoiceProcessing ? .spokenAudio : .default
    }

    func configureForRecording() throws {
        let mode = bestModeForCurrentRoute()
        do {
            try session.setCategory(.playAndRecord, mode: mode, options: [
                .allowBluetooth,
                .defaultToSpeaker
            ])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)

            // Audit session state after activation
            let s = self.session
            let route = s.currentRoute
            let inputs = route.inputs.map { "\($0.portName)" }.joined(separator: ", ")
            let sr = s.sampleRate
            let ioBuf = s.ioBufferDuration
            AppLog.audio.info("Session: sampleRate=\(sr)Hz ioBuffer=\(String(format: "%.1f", ioBuf * 1000))ms inputs=[\(inputs.isEmpty ? "none" : inputs)]")
        } catch {
            AppLog.error("audio", "Failed to configure audio session: \(error.localizedDescription)")
            throw AudioSessionError.configurationFailed
        }
    }

    /// Update the audio mode for a new route without deactivating the session.
    /// The engine keeps running — only the category/mode/options change.
    func adaptToRouteChange() {
        let mode = bestModeForCurrentRoute()
        do {
            try session.setCategory(.playAndRecord, mode: mode, options: [
                .allowBluetooth,
                .defaultToSpeaker
            ])
            AppLog.audio.info("Session adapted to route: mode=\(mode.rawValue)")
        } catch {
            AppLog.error("audio", "Failed to adapt session to route change: \(error.localizedDescription)")
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

    /// Best available input port — prefers built-in mic over A2DP-only Bluetooth devices.
    var bestAvailableInput: AVAudioSessionPortDescription? {
        let inputs = session.currentRoute.inputs
        // Filter to only inputs with actual channels
        let viable = inputs.filter { ($0.channels?.count ?? 0) > 0 }
        // Prefer non-A2DP inputs (A2DP is music-only, no mic)
        if let hfp = viable.first(where: { $0.portType != .bluetoothA2DP && $0.portType != .bluetoothLE }) {
            return hfp
        }
        return viable.first
    }

    /// Human-readable description of current route for logging.
    var routeDescription: String {
        let inputs = session.currentRoute.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ",")
        return "inputs=[\(inputs.isEmpty ? "none" : inputs)] outputs=[\(outputs.isEmpty ? "none" : outputs)]"
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
