import AVFoundation
import UIKit
import OSLog

// MARK: - Capture Profile

/// Encapsulates audio session configuration for different capture scenarios.
/// Replaces scattered flags with a single, auditable profile.
///
/// Guideline: "Persistir 'perfil de captura' é melhor que espalhar flags."
enum CaptureProfile: String, CaseIterable, Sendable {
    /// General voice memo / meeting recording.
    /// Uses .spokenAudio for Apple's voice-optimized DSP (noise suppression, echo cancel).
    case voiceMemo

    /// Voice memo without Apple's voice processing. Raw signal, better for
    /// acoustic analysis or when you want your own DSP chain.
    case voiceMemoRaw

    /// Raw capture for measurement, FFT, acoustic ML.
    /// Uses .measurement mode — minimal system DSP.
    case measurement

    /// Video recording context — camera-aware mic selection.
    case video

    /// Interview / bidirectional — caller + callee both speaking.
    /// Uses .voiceChat for DSP optimized for real-time voice.
    case interview

    /// Whether this profile applies Apple's voice DSP (noise suppression, AGC, echo cancel).
    var usesVoiceProcessing: Bool {
        switch self {
        case .voiceMemo, .interview: true
        case .voiceMemoRaw, .measurement, .video: false
        }
    }

    var category: AVAudioSession.Category {
        switch self {
        case .voiceMemo, .voiceMemoRaw, .measurement:
            return .record           // No playback needed — cleaner routing
        case .video:
            return .playAndRecord    // May play preview through speaker
        case .interview:
            return .playAndRecord    // Bidirectional
        }
    }

    var mode: AVAudioSession.Mode {
        switch self {
        case .voiceMemo:
            return .spokenAudio      // Apple voice DSP: noise suppression, echo cancel, AGC
        case .voiceMemoRaw:
            return .default          // No DSP — raw signal for custom processing
        case .measurement:
            return .measurement      // Raw, no DSP
        case .video:
            return .videoRecording   // Camera-aware mic array
        case .interview:
            return .voiceChat        // Real-time voice DSP
        }
    }

    var options: AVAudioSession.CategoryOptions {
        switch self {
        case .voiceMemo, .voiceMemoRaw, .measurement:
            return [.allowBluetoothHFP]  // BT headset support, no speaker default
        case .video:
            return [.allowBluetoothHFP, .defaultToSpeaker]
        case .interview:
            return [.allowBluetoothHFP, .allowBluetooth, .defaultToSpeaker]
        }
    }

    /// Human-readable description for debug logs.
    var debugDescription: String {
        "\(rawValue): category=\(category.rawValue) mode=\(mode.rawValue) voiceDSP=\(usesVoiceProcessing)"
    }
}

// MARK: - Voice Processing Preference

/// User preference for Apple's built-in voice processing.
/// Stored in UserDefaults, defaults to enabled (.spokenAudio).
enum VoiceProcessingMode: String, CaseIterable, Sendable {
    case enhanced = "Enhanced (recommended)"
    case raw = "Raw (no DSP)"

    var profile: CaptureProfile {
        switch self {
        case .enhanced: .voiceMemo
        case .raw: .voiceMemoRaw
        }
    }
}

// MARK: - Audio Session Error

enum AudioSessionError: Error, LocalizedError {
    case configurationFailed(String)
    case permissionDenied
    case diskFull
    case noInputRoute

    var errorDescription: String? {
        switch self {
        case .configurationFailed(let reason): "Audio session configuration failed: \(reason)"
        case .permissionDenied: "Microphone permission denied"
        case .diskFull: "Not enough storage space"
        case .noInputRoute: "No audio input available"
        }
    }
}

// MARK: - Audio Session Manager

final class AudioSessionManager {
    private let session: AVAudioSession

    /// Current capture profile. Setting it after recording has started
    /// triggers a full rebuild (stop → reconfigure → restart).
    private(set) var currentProfile: CaptureProfile = .voiceMemo

    /// User preference for voice processing mode. Persisted in UserDefaults.
    static var voiceProcessingMode: VoiceProcessingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "voice_processing_mode") ?? ""
            return VoiceProcessingMode(rawValue: raw) ?? .enhanced
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "voice_processing_mode")
        }
    }

    /// Resolved profile based on user preference.
    static var resolvedVoiceProfile: CaptureProfile {
        voiceProcessingMode.profile
    }

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        // Apply user preference on init
        self.currentProfile = Self.resolvedVoiceProfile
    }

    // MARK: - Permission

    /// Use the modern API for record permission.
    /// Guideline: "Use AVAudioApplication.requestRecordPermission em targets modernos."
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Configuration

    /// Configure session for a specific capture profile.
    /// Guideline: "Use setCategory(_:mode:options:), não chamadas antigas separadas."
    func configure(for profile: CaptureProfile) throws {
        let oldProfile = currentProfile

        do {
            // Atomic set: category + mode + options together
            try session.setCategory(profile.category, mode: profile.mode, options: profile.options)
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)

            try session.setActive(true)
            currentProfile = profile

            // Audit the session state after activation
            logSessionState()

            AppLog.audio.info("Session configured: profile=\(profile.debugDescription)")
        } catch {
            AppLog.error("audio", "Failed to configure session for \(profile.debugDescription): \(error.localizedDescription)")
            currentProfile = oldProfile
            throw AudioSessionError.configurationFailed(error.localizedDescription)
        }
    }

    /// Convenience for the legacy API — always uses voiceMemo.
    func configureForRecording() throws {
        try configure(for: .voiceMemo)
    }

    /// Reconfigure session (used for profile switching during recording).
    /// Guideline: "Ao mudar categoria/mode, considere rebuild completo."
    func reconfigure(for newProfile: CaptureProfile) throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try configure(for: newProfile)
    }

    // MARK: - Deactivation

    /// Deactivate the audio session.
    /// Guideline: "Use setActive(false, options: .notifyOthersOnDeactivation)"
    func deactivate() throws {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            AppLog.audio.info("Session deactivated")
        } catch {
            AppLog.error("audio", "Failed to deactivate audio session: \(error.localizedDescription)")
            throw AudioSessionError.configurationFailed(error.localizedDescription)
        }
    }

    // MARK: - Session state audit

    /// Log the full audio session state for debugging.
    /// Guideline: "Audite a sessão em runtime."
    func logSessionState() {
        let route = session.currentRoute
        let inputs = route.inputs.map { p in
            let ds = p.dataSources?.first.map { "ds=\($0.dataSourceName)" } ?? "ds=none"
            let pp = p.selectedDataSource?.supportedPolarPatterns?.map(\.rawValue).joined(separator: ",") ?? "none"
            return "\(p.portName)(\(p.portType.rawValue))[\(ds),polar=\(pp)]"
        }.joined(separator: ", ")

        AppLog.audio.info("""
            Session audit:
              profile=\(self.currentProfile.debugDescription)
              sampleRate=\(self.sampleRate)Hz ioBuffer=\(String(format: "%.1f", self.ioBufferDuration * 1000))ms
              inputCount=\(self.session.isInputAvailable ? String(self.session.currentRoute.inputs.count) : "none")
              inputs=[\(inputs.isEmpty ? "none" : inputs)]
              inputGainSettable=\(self.session.isInputGainSettable)
              outputVolume=\(String(format: "%.2f", self.session.outputVolume))
            """)
    }

    // MARK: - Disk space

    func hasMinimumDiskSpace(requiredBytes: Int64 = 50_000_000) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                return freeSize >= requiredBytes
            }
            return true
        } catch {
            AppLog.audio.warning("Could not check disk space: \(error)")
            return true
        }
    }

    // MARK: - Queries

    var isConfigured: Bool {
        session.category == currentProfile.category
    }

    var isInputAvailable: Bool {
        // Check actual input channels, not just route presence
        session.currentRoute.inputs.contains { ($0.channels?.count ?? 0) > 0 }
    }

    /// Read actual sample rate after activation.
    /// Guideline: "Depois de ativar a sessão, leia session.sampleRate."
    var sampleRate: Double {
        session.sampleRate
    }

    /// Read actual IO buffer duration after activation.
    var ioBufferDuration: TimeInterval {
        session.ioBufferDuration
    }

    var currentInputPortName: String {
        guard let input = session.currentRoute.inputs.first else {
            return "No Microphone"
        }
        switch input.portType {
        case .builtInMic, .builtInReceiver:
            return UIDevice.current.model
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

    var currentInputIcon: String {
        guard let input = session.currentRoute.inputs.first else { return "mic.slash" }
        switch input.portType {
        case .builtInMic, .builtInReceiver: return "iphone"
        case .headsetMic, .headphones: return "headphones"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "airpodspro.chargingcase.wireless.fill"
        case .carAudio: return "car.fill"
        case .usbAudio: return "cable.connector"
        default: return "mic.fill"
        }
    }

    /// Available input data sources for the current route.
    var availableDataSources: [AVAudioSessionDataSourceDescription] {
        session.currentRoute.inputs.first?.dataSources ?? []
    }

    /// Currently selected data source (if any).
    var selectedDataSource: AVAudioSessionDataSourceDescription? {
        session.currentRoute.inputs.first?.selectedDataSource
    }

    // MARK: - Microphone selection

    /// Select the best microphone for meeting recording.
    /// iPhone has multiple mics: bottom (calls), front (FaceTime), back (video).
    /// For meetings: prefer front mic (closer to user's face, better voice pickup).
    /// Guideline: "Não pense em 'o microfone do iPhone'; pense em array de microfones."
    func selectBestMicrophone() {
        guard let builtInMic = session.availableInputs?.first(where: {
            $0.portType == .builtInMic
        }) else {
            AppLog.audio.info("No built-in mic found — using system default")
            return
        }

        // Set the built-in mic as preferred input
        do {
            try session.setPreferredInput(builtInMic)
            AppLog.audio.info("Selected built-in mic: \(builtInMic.portName)")
        } catch {
            AppLog.audio.warning("Failed to set preferred input: \(error.localizedDescription)")
        }

        // Now select the best data source on this mic
        guard let dataSources = builtInMic.dataSources, !dataSources.isEmpty else {
            AppLog.audio.info("No data sources available — using default")
            return
        }

        // Log all available data sources for debugging
        for ds in dataSources {
            let patterns = ds.supportedPolarPatterns?.map(\.rawValue).joined(separator: ",") ?? "none"
            AppLog.audio.debug("Mic DS: '\(ds.dataSourceName)' orientation=\(ds.orientation?.rawValue ?? "nil") polar=\(patterns)")
        }

        // Prefer front-facing mic for meeting recording (closest to user's face)
        // iOS data source orientation: .front = FaceTime camera side, .bottom = Lightning port side
        if let frontMic = dataSources.first(where: { $0.orientation == .front }) {
            do {
                try builtInMic.setPreferredDataSource(frontMic)
                AppLog.audio.info("Selected front microphone: '\(frontMic.dataSourceName)'")
            } catch {
                AppLog.audio.warning("Failed to set front mic: \(error.localizedDescription)")
            }
        } else if let bottomMic = dataSources.first(where: { $0.orientation == .bottom }) {
            do {
                try builtInMic.setPreferredDataSource(bottomMic)
                AppLog.audio.info("Selected bottom microphone (front not available): '\(bottomMic.dataSourceName)'")
            } catch {
                AppLog.audio.warning("Failed to set bottom mic: \(error.localizedDescription)")
            }
        }

        // Select cardioid polar pattern for best voice pickup
        if let selectedDS = session.currentRoute.inputs.first?.selectedDataSource {
            let supportedPatterns = selectedDS.supportedPolarPatterns ?? []
            if supportedPatterns.contains(.cardioid) {
                try? selectedDS.setPreferredPolarPattern(.cardioid)
                AppLog.audio.info("Set polar pattern: cardioid")
            } else if supportedPatterns.contains(.omnidirectional) {
                try? selectedDS.setPreferredPolarPattern(.omnidirectional)
                AppLog.audio.info("Set polar pattern: omnidirectional")
            }
        }

        // Log the final selection
        let finalDS = session.currentRoute.inputs.first?.selectedDataSource
        AppLog.audio.info("Final mic: '\(finalDS?.dataSourceName ?? "system default")'")

        // Update input port name for UI
        _ = currentInputPortName
    }

    // MARK: - Gain control

    /// Whether the current input supports manual gain control.
    var isInputGainSettable: Bool {
        session.isInputGainSettable
    }

    /// Current input gain (0.0 - 1.0). Only valid if isInputGainSettable is true.
    var inputGain: Float {
        get { session.inputGain }
        set {
            guard session.isInputGainSettable else { return }
            let clamped = max(0.0, min(1.0, newValue))
            try? session.setInputGain(clamped)
            AppLog.audio.info("Input gain: \(String(format: "%.2f", clamped))")
        }
    }

    /// Boost input gain by a percentage (0.0 - 1.0).
    func boostGain(by amount: Float = 0.2) -> Float {
        guard session.isInputGainSettable else { return 0 }
        let oldGain = session.inputGain
        let newGain = min(1.0, oldGain + amount)
        inputGain = newGain
        return newGain - oldGain
    }

    /// Reset input gain to system default (0.5).
    func resetGain() {
        guard session.isInputGainSettable else { return }
        try? session.setInputGain(0.5)
        AppLog.audio.info("Input gain reset to 0.5")
    }

    /// Analyze whether gain is too low based on audio level samples.
    /// Returns true if gain boost is recommended.
    func shouldBoostGain(levelSamples: [Float], threshold: Float = 0.02) -> Bool {
        guard session.isInputGainSettable, !levelSamples.isEmpty else { return false }
        let avg = levelSamples.reduce(0, +) / Float(levelSamples.count)
        return avg < threshold && session.inputGain < 0.9
    }

    // MARK: - Input watchdog

    /// Start monitoring for input buffer stalls.
    /// If no buffer arrives within `timeout` seconds, the callback fires.
    func startInputWatchdog(timeout: TimeInterval = 2.0, onStall: @escaping @Sendable () -> Void) -> InputWatchdog {
        InputWatchdog(timeout: timeout, onStall: onStall)
    }
}

// MARK: - Input Watchdog

/// Monitors audio input for buffer stalls.
/// Guideline: "Implemente watchdog de entrada. Se não recebe buffers por N ms, marque falha."
///
/// Usage:
/// ```swift
/// let watchdog = sessionManager.startInputWatchdog(timeout: 2.0) {
///     AppLog.error("audio", "Input stalled — no buffers for 2s")
///     rebuildEngine()
/// }
/// // On each buffer received:
/// watchdog.feed()
/// // When recording stops:
/// watchdog.cancel()
/// ```
final class InputWatchdog: @unchecked Sendable {
    private let timeout: TimeInterval
    private let onStall: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.wawa-note.audio.watchdog")
    private var timer: DispatchSourceTimer?
    private var hasFired = false
    private let firedLock = NSLock()

    fileprivate init(timeout: TimeInterval, onStall: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onStall = onStall
        start()
    }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + timeout, repeating: timeout)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.firedLock.withLock {
                guard !self.hasFired else { return }
                self.hasFired = true
            }
            AppLog.error("audio", "Input watchdog fired — no buffers received for \(Int(self.timeout))s")
            self.onStall()
        }
        t.resume()
        self.timer = t
    }

    /// Call this on every audio buffer received to reset the watchdog.
    func feed() {
        firedLock.withLock { hasFired = false }
        timer?.schedule(deadline: .now() + timeout, repeating: timeout)
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        cancel()
    }
}
