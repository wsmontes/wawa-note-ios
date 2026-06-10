import AVFoundation
import OSLog

// MARK: - State enums

/// Physical capture state. The logical recording is alive in all states
/// except .idle, .stopped, and .failedFatal. Route failure is a temporary
/// capture outage, not the end of the recording.
enum AudioCaptureState: Equatable {
    case idle
    case recording
    case pausedByUser
    case reconfiguringRoute
    case waitingForUsableInput
    case interruptedBySystem
    case failedFatal(String)
    case stopped
}

/// The user's recording intention. Central source of truth for whether
/// auto-recovery should happen after route changes.
enum RecordingIntent {
    case none
    case userWantsRecording
    case userPaused
    case userStopped
}

enum AudioCaptureError: Error {
    case engineStartFailed
    case inputNodeUnavailable
    case permissionDenied
    case diskFull
}

enum AudioRebuildResult: Sendable {
    case resumed(AudioRouteSnapshot)
    case paused(AudioRouteSnapshot)
    case noUsableInput(AudioRouteSnapshot)
    case engineFailed(Error, AudioRouteSnapshot)
}

/// Snapshot of the audio route at a point in time, for diagnostics
/// and state-machine decision making.
struct AudioRouteSnapshot: Sendable {
    let currentInputs: [String]
    let currentOutputs: [String]
    let availableInputs: [String]
    let selectedInput: String?
    let selectedInputType: String?
    let isInputUsable: Bool
    let previousInputs: [String]?
    let previousOutputs: [String]?
    let sampleRate: Double
    let bufferDuration: TimeInterval
    let routeChangeReason: String
}

// MARK: - AudioCaptureService

final class AudioCaptureService: ObservableObject, @unchecked Sendable {
    private var engine: AVAudioEngine
    let fileWriter: AudioFileWriter
    private let sessionManager: AudioSessionManager

    @Published private(set) var state: AudioCaptureState = .idle
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var elapsedTime: TimeInterval = 0.0
    @Published private(set) var audioInterruptionReason: String?
    @Published private(set) var currentInputPortName: String = ""

    /// Called when segments transition. closedInfo has the PREVIOUS segment's metadata
    /// (nil for the first segment). newSegment is the segment just created.
    var onSegmentCreated: ((_ closedInfo: ClosedSegmentInfo?, _ newSegment: RecordingSegment) -> Void)?

    /// Called when a segment is closed without a new one opening (e.g., interruption began).
    /// The coordinator should finalize that segment's endedAt / fileSize in the manifest.
    var onSegmentClosed: ((_ closedInfo: ClosedSegmentInfo) -> Void)?

    // MARK: - Internal state

    private var timerTask: Task<Void, Never>?
    private var levelMonitorTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var currentMeetingId: UUID?

    /// The user's intent. Central source of truth — auto-recovery only happens
    /// when recordingIntent == .userWantsRecording.
    private var recordingIntent: RecordingIntent = .none

    /// Saved state before a system interruption (phone call, alarm). Used only
    /// for AVAudioSession.interruptionNotification, not for route changes.
    private var stateBeforeSystemInterruption: AudioCaptureState?

    /// Incremented on each new route-recovery attempt. Async rebuilds check
    /// this token before applying success — prevents a stale recovery from
    /// transitioning to .recording after the user already pressed Stop.
    private var routeRecoveryGeneration: UUID = UUID()

    /// Debounce task for route change notifications — Bluetooth transitions can fire
    /// multiple notifications in quick succession. We collapse them into one settled
    /// evaluation after 500ms.
    private var routeChangeTask: Task<Void, Never>?

    private let audioLevelLock = NSLock()
    private nonisolated(unsafe) var rawAudioLevel: Float = 0.0

    // AudioFileWriter serializes all writes internally — no external write queue needed.

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
        // Propagate write failures (e.g., disk full) — fatal, not recoverable.
        fileWriter.onWriteFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.recordingIntent == .userWantsRecording else { return }

                let reason: String
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
                    reason = "Recording stopped — storage is full."
                } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
                    reason = "Recording stopped — storage is full."
                } else {
                    reason = "Recording stopped — write failed (\(error.localizedDescription))."
                }

                self.timerTask?.cancel()
                if let closed = self.fileWriter.closeCurrentSegment() {
                    self.onSegmentClosed?(closed)
                }
                self.transition(to: .failedFatal(reason), reason: "writeFailure")
                self.audioInterruptionReason = reason
                AppLog.error("audio", "Recording terminated by write failure: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        removeAudioNotificationObservers()
    }

    // MARK: - State machine

    /// Single point of state mutation. Every state change goes through here.
    private func transition(to newState: AudioCaptureState, reason: String) {
        let oldState = state
        state = newState
        AppLog.audio.info("State: \(String(describing: oldState)) → \(String(describing: newState)) — \(reason)")
    }

    /// Capture the current audio route for diagnostics and state-machine decisions.
    private func takeRouteSnapshot(reason: String, previousInputs: [String]? = nil, previousOutputs: [String]? = nil) -> AudioRouteSnapshot {
        let inputs = sessionManager.session.currentRoute.inputs
        let outputs = sessionManager.session.currentRoute.outputs
        let avail = sessionManager.session.availableInputs ?? inputs
        let selected = sessionManager.bestAvailableInput
        return AudioRouteSnapshot(
            currentInputs: inputs.map { "\($0.portName)(\($0.portType.rawValue))" },
            currentOutputs: outputs.map { "\($0.portName)(\($0.portType.rawValue))" },
            availableInputs: avail.map { "\($0.portName)(\($0.portType.rawValue))" },
            selectedInput: selected.map { "\($0.portName)(\($0.portType.rawValue))" },
            selectedInputType: selected?.portType.rawValue,
            isInputUsable: sessionManager.isInputAvailable,
            previousInputs: previousInputs,
            previousOutputs: previousOutputs,
            sampleRate: sessionManager.sampleRate,
            bufferDuration: sessionManager.session.ioBufferDuration,
            routeChangeReason: reason
        )
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
        currentMeetingId = meetingId
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

        transition(to: .recording, reason: "startRecording succeeded")
        recordingIntent = .userWantsRecording
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
        // callback skips file writes while state is .pausedByUser.
        transition(to: .pausedByUser, reason: "user paused")
        recordingIntent = .userPaused
        timerTask?.cancel()
        AppLog.audio.info("Recording paused (engine kept alive)")
    }

    func resumeRecording() {
        guard state == .pausedByUser || state == .interruptedBySystem || state == .waitingForUsableInput else { return }
        if state == .waitingForUsableInput || state == .interruptedBySystem {
            Task { @MainActor in await attemptResume() }
            return
        }
        transition(to: .recording, reason: "user resumed from pause")
        recordingIntent = .userWantsRecording
        startTimer()
        AppLog.audio.info("Recording resumed")
    }

    func stopRecording() {
        guard state == .recording || state == .pausedByUser || state == .waitingForUsableInput || state == .interruptedBySystem || state == .reconfiguringRoute else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timerTask?.cancel()
        timerTask = nil
        levelMonitorTask?.cancel()
        removeAudioNotificationObservers()
        try? sessionManager.deactivate()

        fileWriter.finishRecording()
        transition(to: .stopped, reason: "user stopped")
        recordingIntent = .userStopped
        routeRecoveryGeneration = UUID()  // Invalidate all pending recoveries
        audioLevel = 0.0
        elapsedTime = 0.0
        recordingStartTime = nil
        currentInputPortName = ""
        currentMeetingId = nil
        stateBeforeSystemInterruption = nil
        AppLog.audio.info("Recording stopped")
    }

    func resetToIdle() {
        guard state == .stopped else { return }
        transition(to: .idle, reason: "reset")
        recordingIntent = .none
    }

    // MARK: - Engine rebuild

    /// Install the audio tap. Copies raw PCM samples and dispatches to the
    /// AudioFileWriter's internal serial queue. The writer is the single
    /// serialization point for all audio data — no external write queue needed.
    private func installTap() {
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateAudioLevel(from: buffer)
            guard self.state == .recording else { return }

            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            // AudioFileWriter serializes all writes internally.
            // The tap callback creates the Array on the real-time thread (fast copy),
            // then the writer's queue owns buffer creation and file I/O.
            let fmt = buffer.format
            self.fileWriter.write(samples: samples, frameLength: frameLength, format: fmt)
        }
    }

    /// Rebuild engine for a new audio route. Creates a new file segment.
    /// Does NOT decide final state — returns a result for the state machine.
    @discardableResult
    private func rebuildForNewRoute(reason: String, resumeRecording: Bool, generation: UUID) async -> AudioRebuildResult {
        transition(to: .reconfiguringRoute, reason: "rebuild started: \(reason)")
        timerTask?.cancel()

        // 1. Remove tap, stop engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // 2. Reconfigure session
        try? sessionManager.deactivate()
        do {
            try sessionManager.configureForRecording()
        } catch {
            let snap = takeRouteSnapshot(reason: reason)
            AppLog.error("audio", "rebuildForNewRoute: session reconfigure failed: \(error)")
            audioInterruptionReason = "Could not configure audio."
            return .noUsableInput(snap)
        }

        // 3. Verify input is available AFTER session activation
        guard sessionManager.isInputAvailable else {
            let snap = takeRouteSnapshot(reason: reason)
            audioInterruptionReason = "No microphone available. Check device connection."
            AppLog.error("audio", "rebuildForNewRoute: no input available")
            return .noUsableInput(snap)
        }

        // 4. Get format from session (reflects actual hardware route).
        let sessionRate = sessionManager.sampleRate
        let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false)!
        engine.reset()

        guard let meetingId = currentMeetingId else {
            audioInterruptionReason = "Internal error: no meeting ID."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        // 5. Rotate to new segment — close old + open new atomically.
        let closedInfo: ClosedSegmentInfo?
        do {
            closedInfo = try fileWriter.rotateToNewSegment(meetingId: meetingId, format: hwFmt)
        } catch {
            AppLog.error("audio", "rebuildForNewRoute: rotateToNewSegment failed: \(error)")
            audioInterruptionReason = "Could not create audio segment."
            try? sessionManager.deactivate()
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)

        // 6. Start engine with retry
        var lastEngineError: Error?
        var engineStartSucceeded = false

        for attempt in 1...5 {
            if attempt >= 3 {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                engine = AVAudioEngine()
                AppLog.audio.info("Recreated AVAudioEngine for attempt \(attempt)")
            }

            installTap()
            engine.prepare()

            do {
                try engine.start()
                engineStartSucceeded = true
                lastEngineError = nil
                break
            } catch {
                lastEngineError = error
                AppLog.error("audio", "rebuildForNewRoute: engine start attempt \(attempt)/5 failed: \(error.localizedDescription)")
                if attempt < 5 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    engine.reset()
                    try? sessionManager.configureForRecording()
                }
            }
        }

        // Check generation token — stop may have been called during async recovery
        guard generation == routeRecoveryGeneration, recordingIntent == .userWantsRecording || recordingIntent == .userPaused else {
            fileWriter.closeCurrentSegment()
            try? sessionManager.deactivate()
            AppLog.audio.info("Rebuild cancelled — generation token mismatch or intent changed")
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        if !engineStartSucceeded {
            audioInterruptionReason = "Bluetooth audio not ready. Try again or disconnect."
            fileWriter.closeCurrentSegment()
            if let closed = closedInfo { onSegmentClosed?(closed) }
            try? sessionManager.deactivate()
            return .engineFailed(lastEngineError!, takeRouteSnapshot(reason: reason))
        }

        // 7. Success — emit new segment
        let snap = takeRouteSnapshot(reason: reason)
        let segment = RecordingSegment(
            id: UUID(), index: segIndex,
            fileName: segFileName,
            startedAt: Date(),
            inputPortName: sessionManager.currentInputPortName,
            inputPortType: sessionManager.bestAvailableInput?.portType.rawValue ?? "unknown",
            routeChangeReason: reason,
            sampleRate: hwFmt.sampleRate
        )
        onSegmentCreated?(closedInfo, segment)
        currentInputPortName = sessionManager.currentInputPortName
        audioInterruptionReason = nil

        if resumeRecording {
            transition(to: .recording, reason: "rebuild succeeded: \(reason)")
            startTimer()
            return .resumed(snap)
        } else {
            transition(to: .pausedByUser, reason: "rebuild succeeded (paused): \(reason)")
            return .paused(snap)
        }
    }

    // Simple engine rebuild without segment creation (used for startRecording only).
    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        installTap()
        engine.prepare()
        for attempt in 0...2 {
            do {
                try engine.start()
                return
            } catch {
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.25)
                    engine.reset()
                    engine.prepare()
                }
            }
        }
        transition(to: .waitingForUsableInput, reason: "rebuildEngine failed")
        audioInterruptionReason = "Audio system unavailable."
    }

    // MARK: - Interruption recovery

    /// Attempt to recover from an interrupted/waiting state.
    /// - Parameter forceRecording: if true, always resume as .recording.
    func attemptResume(forceRecording: Bool = false) async {
        guard state == .interruptedBySystem || state == .waitingForUsableInput else { return }
        let shouldRecord = forceRecording || recordingIntent == .userWantsRecording
        let gen = routeRecoveryGeneration
        let result = await rebuildForNewRoute(reason: forceRecording ? "manualResume" : "recovery", resumeRecording: shouldRecord, generation: gen)

        switch result {
        case .resumed:
            recordingIntent = .userWantsRecording
        case .paused:
            recordingIntent = .userPaused
        case .noUsableInput:
            transition(to: .waitingForUsableInput, reason: "resume failed: no usable input")
            if audioInterruptionReason == nil {
                audioInterruptionReason = "Waiting for a usable microphone…"
            }
        case .engineFailed:
            transition(to: .waitingForUsableInput, reason: "resume failed: engine")
            if audioInterruptionReason == nil {
                audioInterruptionReason = "Bluetooth audio not ready. Try again or disconnect."
            }
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
            AppLog.event("audio", "System interruption began — state=\(state)")
            stateBeforeSystemInterruption = state
            if state == .recording {
                transition(to: .interruptedBySystem, reason: "system interruption began")
                audioInterruptionReason = "Recording paused due to interruption (phone call, alarm, etc.)."
                timerTask?.cancel()
                if let closed = fileWriter.closeCurrentSegment() {
                    onSegmentClosed?(closed)
                }
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            if options?.contains(.shouldResume) == true,
               recordingIntent == .userWantsRecording {
                AppLog.audio.info("System interruption ended — rebuilding")
                let gen = routeRecoveryGeneration
                Task { @MainActor in
                    _ = await rebuildForNewRoute(reason: "interruptionEnded", resumeRecording: true, generation: gen)
                }
            } else if state == .interruptedBySystem {
                transition(to: .pausedByUser, reason: "interruption ended without shouldResume")
                recordingIntent = .userPaused
                audioInterruptionReason = "Interruption ended. Recording paused."
            }
            stateBeforeSystemInterruption = nil
        @unknown default:
            break
        }
    }

    /// Route changes require an engine rebuild to switch to the new input.
    /// The tap(format: nil) auto-adapts to format, but the engine MUST be
    /// restarted to capture from the new device.
    ///
    /// Bluetooth transitions fire multiple notifications rapidly — debounce by
    /// 500ms so we evaluate the settled route, not an intermediate state where
    /// input may appear unavailable.
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        AppLog.audio.info("Audio route change notification: reason=\(reason.rawValue)")

        routeChangeTask?.cancel()
        routeChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.processSettledRouteChange(reason)
        }
    }

    @MainActor
    private func processSettledRouteChange(_ reason: AVAudioSession.RouteChangeReason) async {
        let portName = sessionManager.currentInputPortName
        let inputAvailable = sessionManager.isInputAvailable
        AppLog.audio.info("Route settled: reason=\(reason.rawValue) port=\(portName) inputAvailable=\(inputAvailable)")

        // Input lost while recording or user-paused
        guard inputAvailable else {
            if recordingIntent == .userWantsRecording || recordingIntent == .userPaused {
                transition(to: .waitingForUsableInput, reason: "input lost")
                audioInterruptionReason = "Microphone disconnected. Waiting for input…"
                timerTask?.cancel()
                if let closed = fileWriter.closeCurrentSegment() {
                    onSegmentClosed?(closed)
                }
                AppLog.audio.info("Input lost")
            }
            return
        }

        // Input returned while waiting — auto-recover if user wants recording
        if state == .waitingForUsableInput, currentMeetingId != nil {
            if recordingIntent == .userWantsRecording {
                AppLog.audio.info("Input recovered — auto-rebuilding")
                let gen = routeRecoveryGeneration
                _ = await rebuildForNewRoute(reason: "routeRecovered", resumeRecording: true, generation: gen)
            } else if recordingIntent == .userPaused {
                // Reconfigure route but stay paused
                let gen = routeRecoveryGeneration
                _ = await rebuildForNewRoute(reason: "routeRecovered", resumeRecording: false, generation: gen)
            }
            return
        }

        // Route changed while recording or user-paused — rebuild
        guard recordingIntent == .userWantsRecording || recordingIntent == .userPaused else {
            currentInputPortName = portName
            return
        }

        let resume = recordingIntent == .userWantsRecording
        let gen = routeRecoveryGeneration
        let result = await rebuildForNewRoute(reason: String(reason.rawValue), resumeRecording: resume, generation: gen)
        currentInputPortName = portName
        if case .noUsableInput = result, resume {
            transition(to: .waitingForUsableInput, reason: "route change rebuild failed")
        } else if case .engineFailed = result, resume {
            transition(to: .waitingForUsableInput, reason: "route change engine failed")
        }
        AppLog.audio.info("Route change handled: \(portName)")
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        AppLog.error("audio", "Media services reset — rebuilding with new segment")
        if recordingIntent == .userWantsRecording || recordingIntent == .userPaused {
            let resume = recordingIntent == .userWantsRecording
            let gen = routeRecoveryGeneration
            Task { @MainActor in
                _ = await rebuildForNewRoute(reason: "mediaServicesReset", resumeRecording: resume, generation: gen)
            }
        }
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
