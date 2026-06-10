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
    let fileWriter: AudioFileWriter
    private let sessionManager: AudioSessionManager

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

    /// 1024 frames = ~23ms at 44.1kHz (was 8192 = 186ms).
    private static let captureBufferSize: AVAudioFrameCount = 1024
    private static let levelDecayFactor: Float = 0.85
    private static let levelUpdateIntervalNS: UInt64 = 30_000_000
    private static let timerUpdateInterval: TimeInterval = 0.1

    var outputFileURL: URL? {
        fileWriter.currentFileURL
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

        // Configure audio session with appropriate mode for current route
        try sessionManager.configureForRecording()

        // Create file BEFORE engine start using session sample rate (reflects
        // current audio route). The tap writes raw hardware PCM — file format
        // matches exactly, no upsampling needed.
        let sessionRate = sessionManager.sampleRate > 0 ? sessionManager.sampleRate : 44100
        guard let recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate, channels: 1, interleaved: false) else {
            throw AudioCaptureError.engineStartFailed
        }
        try fileWriter.startRecording(format: recordFormat, meetingId: meetingId)

        installTap()
        engine.prepare()

        // Retry engine start for Bluetooth devices that need time to stabilize
        var engineError: Error?
        for attempt in 0...2 {
            do {
                try engine.start()
                engineError = nil
                break
            } catch {
                engineError = error
                AppLog.error("audio", "Engine start attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    engine.reset()
                    engine.prepare()
                }
            }
        }

        if let engineError {
            AppLog.error("audio", "All engine start attempts failed: \(engineError.localizedDescription)")
            engine.inputNode.removeTap(onBus: 0)
            fileWriter.finishRecording()
            try? sessionManager.deactivate()
            throw AudioCaptureError.engineStartFailed
        }

        state = .recording
        currentInputPortName = sessionManager.currentInputPortName
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
        currentInputPortName = ""
        stateBeforeInterruption = nil
        AppLog.audio.info("Recording stopped")
    }

    func resetToIdle() {
        guard state == .stopped else { return }
        state = .idle
    }

    // MARK: - Engine rebuild

    /// Install the audio tap. Copies raw PCM samples and dispatches to the
    /// write queue. No upsampling — file format matches hardware format exactly.
    private func installTap() {
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateAudioLevel(from: buffer)
            guard self.state == .recording else { return }

            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            self.audioWriteQueue.async { [weak self] in
                guard let self, let file = self.fileWriter.activeFile else { return }
                let fmt = file.processingFormat
                guard let wb = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameLength)) else { return }
                wb.frameLength = AVAudioFrameCount(frameLength)
                if let dest = wb.floatChannelData {
                    dest[0].initialize(from: samples, count: frameLength)
                }
                self.fileWriter.write(buffer: wb)
            }
        }
    }

    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        installTap()
        engine.prepare()

        // Retry up to 2 times if engine start fails (can happen during rapid route changes)
        for attempt in 0...2 {
            do {
                try engine.start()
                AppLog.audio.info("Engine rebuilt successfully\(attempt > 0 ? " (attempt \(attempt + 1))" : "")")
                return
            } catch {
                AppLog.error("audio", "Engine rebuild attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt < 2 {
                    // Brief pause then retry — route may still be stabilizing
                    Thread.sleep(forTimeInterval: 0.25)
                    engine.reset()
                    engine.prepare()
                }
            }
        }
        // All attempts failed
        state = .interrupted
        audioInterruptionReason = "Audio system unavailable. Check connected devices."
    }

    // MARK: - Interruption recovery

    func attemptResume() {
        guard state == .interrupted else { return }

        try? sessionManager.deactivate()
        do {
            try sessionManager.configureForRecording()
        } catch {
            AppLog.error("audio", "Failed to reconfigure session during resume attempt: \(error.localizedDescription)")
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

    /// Route changes (Bluetooth connect/disconnect, AirPods in/out, etc.) are handled
    /// automatically by AVAudioEngine when the tap uses format: nil. The engine keeps
    /// running and adapts to the new input format.
    ///
    /// We update the audio session mode for the new route (built-in mic gets .spokenAudio,
    /// Bluetooth gets .default) WITHOUT deactivating the session.
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        let newPort = sessionManager.currentInputPortName
        AppLog.audio.info("Audio route changed: reason=\(reason.rawValue) port=\(newPort)")

        // Adapt audio mode to new route without stopping the engine
        sessionManager.adaptToRouteChange()

        // Update UI
        currentInputPortName = newPort

        // If no input is available at all, pause recording
        if !sessionManager.isInputAvailable && (state == .recording || state == .paused) {
            state = .interrupted
            audioInterruptionReason = "No microphone available."
            timerTask?.cancel()
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
