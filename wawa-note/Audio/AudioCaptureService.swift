import AVFoundation
import OSLog

enum AudioCaptureState {
    case idle
    case recording
    case paused
    case interrupted
    case stopped
}

enum AudioCaptureError: Error {
    case engineStartFailed
    case inputNodeUnavailable
    case permissionDenied
    case diskFull
}

final class AudioCaptureService: ObservableObject, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let fileWriter: AudioFileWriter
    let sessionManager: AudioSessionManager

    @Published private(set) var state: AudioCaptureState = .idle
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var elapsedTime: TimeInterval = 0.0
    @Published private(set) var audioInterruptionReason: String?
    @Published private(set) var currentInputPortName: String = ""

    private var timerTask: Task<Void, Never>?
    private var levelMonitorTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var stateBeforeInterruption: AudioCaptureState?

    private let audioLevelLock = NSLock()
    private nonisolated(unsafe) var rawAudioLevel: Float = 0.0

    private let audioWriteQueue = DispatchQueue(label: "com.wawa-note.audio.write", qos: .userInitiated)

    /// Input watchdog — fires if no buffers arrive within 2s.
    private var inputWatchdog: InputWatchdog?

    /// Buffer size reduced to ~23ms at 44.1kHz (1024 frames) for finer VAD granularity.
    /// Meetily/anarlog use 30ms chunks; 1024 frames matches their precision.
    private static let captureBufferSize: AVAudioFrameCount = 1024
    private static let levelDecayFactor: Float = 0.85
    private static let levelUpdateIntervalNS: UInt64 = 30_000_000
    private static let timerUpdateInterval: TimeInterval = 0.1

    var outputFileURL: URL? {
        fileWriter.currentFileURL
    }

    /// Whether the captured audio file had write errors (likely corrupted).
    var hasWriteErrors: Bool { fileWriter.hasWriteErrors }

    // MARK: - Software AGC (Automatic Gain Control)

    /// Gain multiplier applied to samples before writing (1.0 = no change).
    /// Increased automatically during auto-calibration if signal is too quiet.
    private nonisolated(unsafe) var softwareGain: Float = 1.0

    /// Samples collected during auto-calibration (first 3 seconds).
    private var calibrationSamples: [Float] = []
    private var calibrationComplete = false
    private let calibrationDuration: TimeInterval = 3.0
    private var calibrationStartTime: Date?
    private let calibrationLock = NSLock()

    /// Target RMS level for auto-calibration (-12dBFS ≈ 0.25 in normalized float).
    private static let targetRMS: Float = 0.25

    /// Boost gain for transcription when signal is very low.
    /// Called after failed transcription to improve next attempt.
    func boostGainForTranscription() {
        let oldGain = self.softwareGain
        self.softwareGain = min(4.0, self.softwareGain * 1.5)
        AppLog.audio.info("AGC: boosted software gain \(String(format: "%.2f", oldGain)) → \(String(format: "%.2f", self.softwareGain))")
    }

    /// Reset software gain to neutral.
    func resetGain() {
        self.softwareGain = 1.0
        self.calibrationComplete = false
        self.calibrationSamples.removeAll()
        AppLog.audio.info("AGC: gain reset to 1.0")
    }

    /// Get recommended hardware gain boost based on calibration.
    func recommendedGainBoost() -> Float {
        guard !calibrationSamples.isEmpty else { return 0 }
        let avgRMS = calibrationSamples.reduce(0, +) / Float(calibrationSamples.count)
        if avgRMS < 0.01 { return 0.4 }  // Very quiet → +40%
        if avgRMS < 0.02 { return 0.2 }  // Quiet → +20%
        return 0
    }

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        fileWriter: AudioFileWriter = AudioFileWriter(),
        sessionManager: AudioSessionManager = AudioSessionManager()
    ) {
        self.engine = engine
        self.fileWriter = fileWriter
        self.sessionManager = sessionManager
    }

    deinit {
        removeAudioNotificationObservers()
    }

    // MARK: - Recording lifecycle

    func startRecording(meetingId: UUID) async throws {
        guard state == .idle else {
            AppLog.warn("audio", "startRecording called while state is \(String(describing: self.state)) — ignoring")
            return
        }
        let granted = await sessionManager.requestPermission()
        guard granted else { throw AudioCaptureError.permissionDenied }

        guard sessionManager.hasMinimumDiskSpace() else {
            AppLog.error("audio", "Insufficient disk space to start recording (needs 50MB free)")
            throw AudioCaptureError.diskFull
        }

        try sessionManager.configureForRecording()

        // Apply recommended hardware gain boost from previous calibration
        // (safe to call after setActive; gain adjustment is allowed on active session)
        let hwBoost = sessionManager.isInputGainSettable ? recommendedGainBoost() : 0
        if hwBoost > 0 {
            let applied = sessionManager.boostGain(by: hwBoost)
            AppLog.audio.info("Applied hardware gain boost: +\(String(format: "%.0f", applied * 100))%")
        }

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        try fileWriter.startRecording(format: hardwareFormat, meetingId: meetingId)

        // Install tap for audio level monitoring + file writing.
        // The engine must keep running (iOS forbids engine.start() in the
        // background), so the tap stays installed for the lifetime of the
        // recording.
        //
        // Buffer PCM data is reused by the audio system after callback return,
        // so we copy frame data before dispatching async. Real-time thread
        // must never do disk I/O or malloc — we do peak detection inline
        // (O(n), no allocations) and copy buffer contents to a pre-allocated
        // slice before dispatching to the write queue.
        // Input watchdog: start monitoring for buffer stalls.
        inputWatchdog = sessionManager.startInputWatchdog(timeout: 2.0) { [weak self] in
            guard let self, self.state == .recording else { return }
            AppLog.error("audio", "Input watchdog triggered — no audio buffers for 2s. Attempting engine rebuild.")
            self.audioInterruptionReason = "Audio input stalled. Attempting recovery..."
            self.rebuildEngine()
        }

        inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.inputWatchdog?.feed()
            self.updateAudioLevel(from: buffer)

            // AGC calibration: DISABLED for debugging
            // Will re-enable once recording works again

            guard self.state == .recording else { return }

            // Copy buffer contents synchronously on the real-time thread
            // (safe: floatChannelData is already allocated, memcpy only).
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)

            let copiedFrames = UnsafeMutablePointer<Float>.allocate(capacity: frameLength)
            copiedFrames.initialize(from: channelData[0], count: frameLength)

            // Dispatch the copied buffer to the write queue.
            self.audioWriteQueue.async { [weak self] in
                guard let self, let file = self.fileWriter.activeFile else {
                    copiedFrames.deallocate()
                    return
                }
                let format = file.processingFormat
                guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength)) else {
                    copiedFrames.deallocate()
                    return
                }
                writeBuffer.frameLength = AVAudioFrameCount(frameLength)
                if let destData = writeBuffer.floatChannelData {
                    destData[0].initialize(from: copiedFrames, count: frameLength)
                }
                copiedFrames.deallocate()

                self.fileWriter.write(buffer: writeBuffer)
            }
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            AppLog.error("audio", "Failed to start audio engine: \(error.localizedDescription)")
            engine.inputNode.removeTap(onBus: 0)
            fileWriter.finishRecording()
            try? sessionManager.deactivate()
            throw AudioCaptureError.engineStartFailed
        }

        state = .recording
        currentInputPortName = sessionManager.currentInputPortName
        calibrationStartTime = Date()
        startTimer()
        startLevelSmoothing()
        observeAudioNotifications()
        AppLog.event("audio", "Audio engine started — input=\(self.currentInputPortName)")
    }

    func pauseRecording() {
        guard state == .recording else { return }
        // Keep the engine running — iOS forbids engine.start() from the
        // background, so we never stop the engine mid-recording. The tap
        // callback skips file writes while state is .paused.
        state = .paused
        timerTask?.cancel()
        AppLog.audio.info("Recording paused (engine kept alive)")
    }

    func resumeRecording() {
        guard state == .paused || state == .interrupted else { return }
        if state == .interrupted {
            attemptResume()
            return
        }
        state = .recording
        startTimer()
        AppLog.audio.info("Recording resumed")
    }

    func stopRecording() {
        guard state == .recording || state == .paused || state == .interrupted else { return }

        inputWatchdog?.cancel()
        inputWatchdog = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timerTask?.cancel()
        timerTask = nil
        levelMonitorTask?.cancel()
        removeAudioNotificationObservers()
        try? sessionManager.deactivate()

        fileWriter.finishRecording()
        state = .stopped
        audioLevel = 0.0
        elapsedTime = 0.0
        recordingStartTime = nil
        calibrationStartTime = nil
        currentInputPortName = ""
        stateBeforeInterruption = nil
        AppLog.audio.info("Recording stopped")
    }

    func resetToIdle() {
        guard state == .stopped else { return }
        state = .idle
    }

    // MARK: - Engine rebuild

    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        let inputNode = engine.inputNode
        // Use the same tap pattern as startRecording — copy frames, dispatch async.
        inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateAudioLevel(from: buffer)
            guard self.state == .recording else { return }

            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let copiedFrames = UnsafeMutablePointer<Float>.allocate(capacity: frameLength)
            copiedFrames.initialize(from: channelData[0], count: frameLength)

            self.audioWriteQueue.async { [weak self] in
                guard let self, let file = self.fileWriter.activeFile else {
                    copiedFrames.deallocate()
                    return
                }
                let format = file.processingFormat
                guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength)) else {
                    copiedFrames.deallocate()
                    return
                }
                writeBuffer.frameLength = AVAudioFrameCount(frameLength)
                if let destData = writeBuffer.floatChannelData {
                    destData[0].initialize(from: copiedFrames, count: frameLength)
                }
                copiedFrames.deallocate()
                self.fileWriter.write(buffer: writeBuffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            AppLog.audio.info("Engine rebuilt successfully")
        } catch {
            AppLog.audio.error("Engine rebuild failed: \(error.localizedDescription)")
            state = .interrupted
            audioInterruptionReason = "Audio system reset. Recording may be affected."
        }
    }

    // MARK: - Interruption recovery

    func attemptResume() {
        guard state == .interrupted else { return }

        try? sessionManager.deactivate()
        do {
            try sessionManager.configureForRecording()
        } catch {
            AppLog.audio.error("Failed to reconfigure session during resume attempt: \(error.localizedDescription)")
            audioInterruptionReason = "Could not resume after interruption"
            return
        }

        rebuildEngine()

        guard state != .interrupted else {
            // rebuildEngine set state to .interrupted — rebuild failed
            audioInterruptionReason = "Could not resume after interruption"
            return
        }

        currentInputPortName = sessionManager.currentInputPortName
        if stateBeforeInterruption == .recording {
            state = .recording
            startTimer()
            audioInterruptionReason = nil
            AppLog.audio.info("Recording resumed after interruption on \(self.currentInputPortName)")
        } else {
            state = .paused
            audioInterruptionReason = nil
            AppLog.audio.info("Engine rebuilt, recording remains paused on \(self.currentInputPortName)")
        }
    }

    // MARK: - Notifications

    // Block-based observers on .main queue guarantee that all @Published
    // mutations and AVAudioEngine operations happen on the main thread.
    // Selector-based observers run on the posting thread (which may be
    // a background thread for route-change notifications), causing
    // thread-safety violations and crashes.

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?

    private func observeAudioNotifications() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleMediaServicesReset(notification)
        }
    }

    private func removeAudioNotificationObservers() {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = mediaServicesResetObserver { NotificationCenter.default.removeObserver(obs) }
        interruptionObserver = nil
        routeChangeObserver = nil
        mediaServicesResetObserver = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            AppLog.event("audio", "Audio session interrupted — type=began prevState=\(state)")
            stateBeforeInterruption = state
            if state == .recording {
                state = .interrupted
                audioInterruptionReason = "Recording paused due to interruption (phone call, alarm, etc.)."
                timerTask?.cancel()
            }
        case .ended:
            // The InterruptionOptionKey may be absent (Apple DTS: no guarantee
            // that every .began has a corresponding .ended with options).
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            if options?.contains(.shouldResume) == true,
               stateBeforeInterruption == .recording || stateBeforeInterruption == .paused {
                AppLog.audio.info("Audio interruption ended — attempting resume with engine rebuild")
                audioInterruptionReason = "Attempting to resume after interruption..."

                // Deactivate first to clear any stale session state
                try? sessionManager.deactivate()
                do {
                    try sessionManager.configureForRecording()
                } catch {
                    AppLog.error("audio", "Failed to reconfigure session after interruption: \(error.localizedDescription)")
                    state = .interrupted
                    audioInterruptionReason = "Could not resume after interruption"
                    stateBeforeInterruption = nil
                    return
                }

                // Always rebuild engine after interruption to fix iOS bugs
                // where tap stops firing after phone calls (e.g. iPhone 16e)
                rebuildEngine()

                if state != .interrupted {
                    state = .recording
                    audioInterruptionReason = nil
                    startTimer()
                    AppLog.event("audio", "Successfully resumed recording after interruption")
                } else {
                    audioInterruptionReason = "Could not resume after interruption"
                }
            } else if state == .interrupted {
                AppLog.audio.info("Audio interruption ended without shouldResume — transitioning to paused")
                audioInterruptionReason = "Interruption ended. Recording paused."
                state = .paused
            }
            stateBeforeInterruption = nil
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            let wasRecording = state == .recording
            AppLog.audio.info("Audio route: old device unavailable — interrupting")
            if state == .recording || state == .paused {
                state = .interrupted
                audioInterruptionReason = "Headphones disconnected. Recording interrupted."
                timerTask?.cancel()
            }
            rebuildEngine()
            currentInputPortName = sessionManager.currentInputPortName
            if wasRecording, state != .interrupted {
                state = .recording
                audioInterruptionReason = nil
                startTimer()
                AppLog.audio.info("Resumed recording after route change to \(self.currentInputPortName)")
            } else if wasRecording {
                audioInterruptionReason = "Could not resume after audio route change."
            }
        case .newDeviceAvailable:
            let newPort = sessionManager.currentInputPortName
            AppLog.audio.info("Audio route: new device available — \(newPort)")

            // Validate the new device actually has input
            guard sessionManager.isInputAvailable else {
                AppLog.audio.warning("New device \(newPort) has no input channels — staying on current route")
                return
            }

            // If we were recording, rebuild engine to switch to the new device
            if state == .recording || state == .paused {
                let wasRecording = state == .recording
                audioInterruptionReason = "Switching to \(newPort)..."
                state = .interrupted
                timerTask?.cancel()
                rebuildEngine()
                if state != .interrupted {
                    currentInputPortName = newPort
                    if wasRecording {
                        state = .recording
                        startTimer()
                    } else {
                        state = .paused
                    }
                    audioInterruptionReason = nil
                    AppLog.audio.info("Successfully switched to \(newPort)")
                } else {
                    audioInterruptionReason = "Could not switch to \(newPort)"
                }
            } else {
                // Not recording — just update the port name for UI
                currentInputPortName = newPort
            }
        case .override, .categoryChange:
            break
        default:
            AppLog.audio.info("Audio route changed: \(reason.rawValue)")
        }
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        AppLog.error("audio", "Catastrophic media services reset detected — engine must be rebuilt")
        if state == .recording || state == .paused {
            state = .interrupted
            audioInterruptionReason = "Audio system reset. Recording may be affected."
            timerTask?.cancel()
        }
        rebuildEngine()
    }

    private func startTimer() {
        timerTask?.cancel()
        recordingStartTime = Date()
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let start = self.recordingStartTime {
                    let elapsed = Date().timeIntervalSince(start)
                    await MainActor.run {
                        self.elapsedTime = elapsed
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.timerUpdateInterval * 1_000_000_000))
            }
        }
    }

    // MARK: - Audio level

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        // Single-pass peak detection: zero heap allocations.
        // Real-time audio threads must never call malloc (Array allocation,
        // map, etc.) — it can block and cause the engine to drop buffers.
        let samples = channelData[0]
        var peak: Float = 0.0
        for i in 0..<frameLength {
            let sample = samples[i]
            let absolute = sample < 0 ? -sample : sample
            if absolute > peak { peak = absolute }
        }
        audioLevelLock.withLock {
            rawAudioLevel = min(1.0, peak * 4.0)
        }
    }

    private func startLevelSmoothing() {
        levelMonitorTask?.cancel()
        levelMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.levelUpdateIntervalNS)
                guard let self else { return }
                self.audioLevelLock.withLock {
                    self.rawAudioLevel *= Self.levelDecayFactor
                }
                let level = self.audioLevelLock.withLock { self.rawAudioLevel }
                await MainActor.run { [weak self] in
                    self?.audioLevel = level
                }
            }
        }
    }
}
