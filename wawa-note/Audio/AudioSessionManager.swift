import AVFoundation
import OSLog
import UIKit

// Related JIRA: KAN-5, KAN-15, KAN-96

enum AudioSessionError: Error {
    case configurationFailed
    case permissionDenied
    case diskFull
}

final class AudioSessionManager {
    let session: AVAudioSession  // internal — read by AudioCaptureService for route snapshots

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

    /// When true, the built-in iPhone mic (48kHz with beamforming) is preferred
    /// over Bluetooth HFP (8kHz mono, call-quality codec). Bluetooth A2DP is
    /// unaffected since it's output-only. Defaults to false (HFP takes priority
    /// for convenience).
    static var preferBuiltInMicOverBluetooth: Bool {
        get { UserDefaults.standard.bool(forKey: "audio_prefer_builtin_mic") }
        set { UserDefaults.standard.set(newValue, forKey: "audio_prefer_builtin_mic") }
    }

    /// Whether the current audio route is CarPlay.
    var isCarPlayActive: Bool {
        session.currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// Whether the current input is from an AirPlay source (e.g., Mac, Apple TV).
    var isAirPlayInput: Bool {
        session.currentRoute.inputs.contains { $0.portType == .airPlay }
    }

    /// Whether any output is routed via AirPlay.
    var isAirPlayActive: Bool {
        session.currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    /// Whether the current input is a Bluetooth device without a microphone
    /// (A2DP profile only — music headphones, not headsets).
    ///
    /// Checks both currentRoute and availableInputs. AirPods may momentarily
    /// appear as A2DP (music profile) in currentRoute while also appearing as
    /// HFP in availableInputs. Only returns true if NO known Bluetooth device
    /// has microphone channels.
    var isBluetoothWithoutMic: Bool {
        let input = session.currentRoute.inputs.first
        guard let port = input else { return false }
        let isBT = port.portType == .bluetoothA2DP || port.portType == .bluetoothLE
        guard isBT else { return false }
        let hasChannels = (port.channels?.count ?? 0) > 0
        if hasChannels { return false }
        // The current route says A2DP/LE without channels, but check availableInputs
        // — the same device may be listed there with HFP capabilities.
        let availableWithMic = (session.availableInputs ?? []).contains { avail in
            (avail.portType == .bluetoothHFP || avail.portType == .bluetoothA2DP || avail.portType == .bluetoothLE)
                && (avail.channels?.count ?? 0) > 0
        }
        return !availableWithMic
    }

    /// Whether any available input (or current route) is a Bluetooth device.
    /// Used to adapt timing — Bluetooth HFP negotiation can take 1-3 seconds.
    var isBluetoothInvolved: Bool {
        let all = (session.availableInputs ?? []) + session.currentRoute.inputs
        return all.contains { input in
            input.portType == .bluetoothHFP
                || input.portType == .bluetoothA2DP
                || input.portType == .bluetoothLE
        }
    }

    /// Whether the best available input is a Bluetooth HFP device.
    /// HFP (Hands-Free Profile) negotiation is the flakiest — needs extended delays.
    var isBluetoothHFPPreferred: Bool {
        bestAvailableInput?.portType == .bluetoothHFP
    }

    /// Post-deactivation settle delay. Bluetooth routes need more time to fully
    /// release hardware resources before reconfiguration.
    var settleDelayNs: UInt64 {
        isBluetoothInvolved ? 750_000_000 : 500_000_000
    }

    /// Maximum time to wait for first audio buffer during route validation.
    /// Bluetooth HFP can take 2-4 seconds to start delivering PCM after engine start.
    var validationTimeoutSeconds: TimeInterval {
        isBluetoothInvolved ? 4.0 : 2.0
    }

    /// Best audio mode for the current route. Different devices need different modes:
    /// - CarPlay / USB → .default (most compatible)
    /// - Bluetooth HFP → .default (voice processing can cause issues)
    /// - Built-in mic → .spokenAudio (voice enhancement) or .videoChat (far-field)
    func bestModeForCurrentRoute() -> AVAudioSession.Mode {
        if isCarPlayActive { return .default }
        if isBluetoothWithoutMic { return .default }
        if isAirPlayActive || isAirPlayInput { return .default }
        let input = session.currentRoute.inputs.first
        if input?.portType == .usbAudio { return .default }
        if input?.portType == .bluetoothHFP { return .default }
        if input?.portType == .headsetMic { return .default }
        // Built-in mic or AirPods with HFP
        if Self.speakerphoneMode { return .videoChat }
        return Self.useVoiceProcessing ? .spokenAudio : .default
    }

    /// Select the best available input for recording, preferring Bluetooth HFP
    /// but falling back to wired USB, headset, and ultimately built-in mic.
    /// Called after setActive(true) so availableInputs are fully populated.
    func selectBestInputForRecording() {
        let inputs = session.availableInputs ?? session.currentRoute.inputs
        let viable = viableInputs(from: inputs)
        let preferred = rankedInputs(from: viable).first

        if let preferred {
            do {
                try session.setPreferredInput(preferred)
                AppLog.audio.info(
                    "Preferred input: \(preferred.portName)(\(preferred.portType.rawValue)) ch=\(preferred.channels?.count ?? 0) | all=\(self.availableInputsDescription)"
                )
            } catch {
                AppLog.audio.error("setPreferredInput failed: \(error.localizedDescription) | all=\(self.availableInputsDescription)")
            }
        } else {
            AppLog.audio.error("No valid recording input. availableInputs=\(self.availableInputsDescription)")
        }
    }

    func configureForRecording() throws {
        do {
            // Category first with neutral mode (.default). The correct mode
            // (spokenAudio, videoChat, etc.) depends on the settled route,
            // which isn't known until setActive(true) completes. Reading
            // currentRoute.inputs before activation can return stale data
            // during Bluetooth transitions, causing the wrong mode to be set
            // and Bluetooth HFP to enter headset profile instead of HFP.
            try session.setCategory(
                .playAndRecord, mode: .default,
                options: [
                    .allowBluetooth,
                    .defaultToSpeaker,
                ])
            if let preferredInput = bestAvailableInput {
                try? session.setPreferredInput(preferredInput)
            }
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)

            // Route is now settled — adapt mode and select best input.
            adaptToRouteChange()
            selectBestInputForRecording()

            // Audit session state after activation
            let snap = self.routeSnapshot(label: "configureForRecording")
            AppLog.audio.info("\(snap)")
        } catch {
            AppLog.error("audio", "Failed to configure audio session: \(error.localizedDescription)")
            throw AudioSessionError.configurationFailed
        }
    }

    /// Update the audio mode for a new route without deactivating the session.
    /// The engine keeps running — only the category/mode/options change.
    func adaptToRouteChange() {
        let mode = bestModeForCurrentRoute()
        let snapshot = routeSnapshot(label: "adaptToRouteChange")
        do {
            try session.setCategory(
                .playAndRecord, mode: mode,
                options: [
                    .allowBluetooth,
                    .defaultToSpeaker,
                ])
            AppLog.audio.info("Session adapted to route: mode=\(mode.rawValue) \(snapshot)")
        } catch {
            AppLog.error("audio", "Failed to adapt session to route change: \(error.localizedDescription) \(snapshot)")
        }
    }

    /// Human-readable snapshot of current audio route for debugging.
    func routeSnapshot(label: String) -> String {
        let inputs = session.currentRoute.inputs.map { port in
            let ch = port.channels?.count ?? 0
            let dataSources = port.dataSources?.map(\.dataSourceName) ?? []
            let ds = dataSources.isEmpty ? "" : " src=[\(dataSources.joined(separator: ","))]"
            return "\(port.portName)(\(port.portType.rawValue) ch=\(ch)\(ds))"
        }.joined(separator: " ")
        let outputs = session.currentRoute.outputs.map { port in
            "\(port.portName)(\(port.portType.rawValue))"
        }.joined(separator: " ")
        let available = (session.availableInputs ?? []).map { port in
            "\(port.portName)(\(port.portType.rawValue) ch=\(port.channels?.count ?? 0))"
        }.joined(separator: " ")
        let mode = session.mode.rawValue
        let category = session.category.rawValue
        let rate = Int(session.sampleRate)
        let ioBuf = String(format: "%.1fms", session.ioBufferDuration * 1000)
        return
            "[\(label)] mode=\(mode) cat=\(category) rate=\(rate)Hz ioBuf=\(ioBuf) | in=[\(inputs.isEmpty ? "none" : inputs)] out=[\(outputs.isEmpty ? "none" : outputs)] avail=[\(available.isEmpty ? "none" : available)]"
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

    /// Disk space check — uses FileManager, not AVAudioSession, so it's safe
    /// to call as a static method without an AVAudioSession instance.
    static func hasMinimumDiskSpace(requiredBytes: Int64 = 50_000_000) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                return freeSize >= requiredBytes
            }
            return true  // If we can't determine, don't block
        } catch {
            AppLog.audio.warning("Could not check disk space: \(error)")
            return true  // Don't block on failure to check
        }
    }

    var isConfigured: Bool {
        session.category == .playAndRecord
    }

    var isInputAvailable: Bool {
        // Check current route first, fall back to availableInputs during Bluetooth transitions.
        let current = session.currentRoute.inputs.contains { ($0.channels?.count ?? 0) > 0 }
        if current { return true }
        return session.availableInputs?.contains { ($0.channels?.count ?? 0) > 0 } ?? false
    }

    /// Best available input port — prefers availableInputs (all known devices) over
    /// currentRoute.inputs (only active right now). During Bluetooth transitions,
    /// currentRoute may be empty while availableInputs still lists valid mics.
    var bestAvailableInput: AVAudioSessionPortDescription? {
        let candidates = session.availableInputs ?? session.currentRoute.inputs
        let viable = viableInputs(from: candidates)
        return rankedInputs(from: viable).first
    }

    /// Second-best available input — used as fallback if the primary disconnects.
    /// Returns nil if only one input is available.
    var fallbackInput: AVAudioSessionPortDescription? {
        let candidates = session.availableInputs ?? session.currentRoute.inputs
        let viable = viableInputs(from: candidates)
        let ranked = rankedInputs(from: viable)
        return ranked.count > 1 ? ranked[1] : nil
    }

    /// Human-readable description of available inputs for logging/UI.
    var availableInputsDescription: String {
        let candidates = session.availableInputs ?? session.currentRoute.inputs
        let viable = viableInputs(from: candidates)
        let ranked = rankedInputs(from: viable)
        return ranked.enumerated().map { "\($0.offset == 0 ? "★" : "·") \($0.element.portName)(\($0.element.portType.rawValue))" }.joined(separator: ", ")
    }

    /// Filter to viable recording inputs (has channels, not music-only Bluetooth).
    private func viableInputs(from inputs: [AVAudioSessionPortDescription]) -> [AVAudioSessionPortDescription] {
        inputs.filter {
            $0.portType != .bluetoothA2DP && $0.portType != .bluetoothLE && ($0.channels?.count ?? 0) > 0
        }
    }

    /// Rank inputs by priority: AirPlay > HFP > wired > USB > built-in.
    private func rankedInputs(from inputs: [AVAudioSessionPortDescription]) -> [AVAudioSessionPortDescription] {
        // Default priority: AirPlay > Bluetooth HFP > headset > USB > built-in mic.
        // When the user prefers quality, built-in mic jumps ahead of Bluetooth HFP
        // (but stays behind AirPlay and wired headset mics, which can be high quality).
        let basePriority: [AVAudioSession.Port]
        if Self.preferBuiltInMicOverBluetooth {
            basePriority = [.airPlay, .headsetMic, .usbAudio, .builtInMic, .bluetoothHFP]
        } else {
            basePriority = [.airPlay, .bluetoothHFP, .headsetMic, .usbAudio, .builtInMic]
        }
        let priority = basePriority
        return inputs.sorted { a, b in
            let pa = priority.firstIndex(of: a.portType) ?? priority.count
            let pb = priority.firstIndex(of: b.portType) ?? priority.count
            return pa < pb
        }
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
        case .airPlay:
            return "AirPlay (\(input.portName))"
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
        case .airPlay:
            return "airplayaudio"
        case .usbAudio:
            return "cable.connector"
        default:
            return "mic.fill"
        }
    }
}
