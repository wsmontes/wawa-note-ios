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

enum AudioRebuildResult: Sendable {
    case resumed
    case paused
    case failed(String)  // specific reason set in audioInterruptionReason
}

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

    private var timerTask: Task<Void, Never>?
    private var levelMonitorTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var currentMeetingId: UUID?
    private var stateBeforeInterruption: AudioCaptureState?

    /// When input is lost during recording, remember whether we should auto-resume
    /// once a valid input returns. Set to true only if state was .recording at loss.
    private var shouldResumeAfterRouteRecovery = false

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
        // Propagate write failures (e.g., disk full) to recording state
        fileWriter.onWriteFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.state == .recording || self.state == .paused else { return }

                self.state = .interrupted
                self.timerTask?.cancel()

                // Close the current segment immediately so the manifest has
                // accurate endedAt / fileSize — don't leave it dangling.
                if let closed = self.fileWriter.closeCurrentSegment() {
                    self.onSegmentClosed?(closed)
                }

                let reason: String
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
                    reason = "Recording stopped — storage is full."
                } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
                    reason = "Recording stopped — storage is full."
                } else {
                    reason = "Recording stopped — write failed (\(error.localizedDescription))."
                }
                self.audioInterruptionReason = reason
                AppLog.error("audio", "Recording interrupted by write failure: \(error.localizedDescription)")
            }
        }
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
            Task { @MainActor in await attemptResume() }
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
        currentMeetingId = nil
        stateBeforeInterruption = nil
        AppLog.audio.info("Recording stopped")
    }

    func resetToIdle() {
        guard state == .stopped else { return }
        state = .idle
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
    /// Used by route changes, interruption ended, and media services reset.
    /// - Parameter reason: why the rebuild is happening (for manifest).
    /// - Parameter resumeRecording: whether to resume .recording after rebuild.
    /// - Returns: .resumed, .paused, or .failed(reason). On failure, state stays
    ///   .interrupted and audioInterruptionReason has the specific cause.
    @discardableResult
    private func rebuildForNewRoute(reason: String, resumeRecording: Bool) async -> AudioRebuildResult {
        let prevState = state
        state = .interrupted  // Prevent tap from writing during transition
        timerTask?.cancel()

        // 1. Remove tap, stop engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // 2. Reconfigure session
        try? sessionManager.deactivate()
        do {
            try sessionManager.configureForRecording()
        } catch {
            AppLog.error("audio", "rebuildForNewRoute: session reconfigure failed: \(error)")
            audioInterruptionReason = "Could not configure audio."
            return .failed(audioInterruptionReason!)
        }

        // 3. Verify input is available AFTER session activation
        guard sessionManager.isInputAvailable else {
            audioInterruptionReason = "No microphone available. Check device connection."
            AppLog.error("audio", "rebuildForNewRoute: no input available")
            return .failed(audioInterruptionReason!)
        }

        // 4. Get format from session (reflects actual hardware route).
        let sessionRate = sessionManager.sampleRate
        let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false)!
        engine.reset()

        guard let meetingId = currentMeetingId else {
            audioInterruptionReason = "Internal error: no meeting ID."
            return .failed(audioInterruptionReason!)
        }

        // 5. Rotate to new segment — close old + open new atomically.
        let closedInfo: ClosedSegmentInfo?
        do {
            closedInfo = try fileWriter.rotateToNewSegment(meetingId: meetingId, format: hwFmt)
        } catch {
            AppLog.error("audio", "rebuildForNewRoute: rotateToNewSegment failed: \(error)")
            audioInterruptionReason = "Could not create audio segment."
            try? sessionManager.deactivate()
            return .failed(audioInterruptionReason!)
        }

        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)

        // 6. Start engine with retry — Bluetooth devices take time to stabilize.
        //    Retry up to 5 attempts with progressive delays.
        var lastEngineError: Error?
        var engineStartSucceeded = false

        for attempt in 1...5 {
            // Recreate engine after 2 failures — Bluetooth can leave the old
            // engine in a bad state even after stop/reset.
            if attempt >= 3 {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                let oldDesc = engine.description
                engine = AVAudioEngine()
                AppLog.audio.info("Recreated AVAudioEngine for attempt \(attempt) (was \(oldDesc.prefix(40)))")
            }

            installTap()
            engine.prepare()

            do {
                try engine.start()
                engineStartSucceeded = true
                lastEngineError = nil
                AppLog.audio.info("Engine started on attempt \(attempt)")
                break
            } catch {
                lastEngineError = error
                AppLog.error("audio", "rebuildForNewRoute: engine start attempt \(attempt)/5 failed: \(error.localizedDescription)")

                if attempt < 5 {
                    let delayNs = UInt64(attempt) * 500_000_000
                    try? await Task.sleep(nanoseconds: delayNs)

                    // Re-prepare session and engine for next attempt
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    engine.reset()
                    try? sessionManager.configureForRecording()
                }
            }
        }

        if !engineStartSucceeded {
            let desc = lastEngineError?.localizedDescription ?? "unknown error"
            audioInterruptionReason = "Bluetooth audio not ready. Try again or disconnect."
            AppLog.error("audio", "rebuildForNewRoute: engine start failed after 5 attempts: \(desc)")
            fileWriter.closeCurrentSegment()  // Discard empty new segment
            // Report the old segment's final metadata — the audio up to this
            // point is preserved on disk. The manifest must record its endedAt.
            if let closed = closedInfo {
                onSegmentClosed?(closed)
            }
            try? sessionManager.deactivate()
            return .failed(audioInterruptionReason!)
        }

        // 7. Emit new segment and restore state
        let segment = RecordingSegment(
            id: UUID(), index: segIndex,
            fileName: segFileName,
            startedAt: Date(),
            inputPortName: self.sessionManager.currentInputPortName,
            inputPortType: self.sessionManager.bestAvailableInput?.portType.rawValue ?? "unknown",
            routeChangeReason: reason,
            sampleRate: hwFmt.sampleRate
        )
        onSegmentCreated?(closedInfo, segment)

        // Update published port info so the UI reflects the new route immediately.
        currentInputPortName = sessionManager.currentInputPortName

        state = resumeRecording ? .recording : .paused
        if resumeRecording { startTimer() }
        audioInterruptionReason = nil
        AppLog.audio.info("Rebuilt for new route: \(self.sessionManager.currentInputPortName) segment=\(segIndex) result=\(resumeRecording ? "resumed" : "paused")")
        return resumeRecording ? .resumed : .paused
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
        state = .interrupted
        audioInterruptionReason = "Audio system unavailable."
    }

    // MARK: - Interruption recovery

    /// Attempt to recover from an interrupted state.
    /// - Parameter forceRecording: if true, always resume as .recording regardless
    ///   of stored previous state. Use this for manual "Resume" button presses.
    func attemptResume(forceRecording: Bool = false) async {
        guard state == .interrupted else { return }
        let shouldRecord = forceRecording
            || shouldResumeAfterRouteRecovery
            || stateBeforeInterruption == .recording
        let result = await rebuildForNewRoute(reason: forceRecording ? "manualResume" : "interruptionEnded", resumeRecording: shouldRecord)
        switch result {
        case .resumed, .paused:
            shouldResumeAfterRouteRecovery = false
            // audioInterruptionReason already cleared by rebuildForNewRoute on success
        case .failed:
            // rebuildForNewRoute already set the specific reason — preserve it.
            // Only use a generic fallback if no reason was set (shouldn't happen).
            if audioInterruptionReason == nil {
                audioInterruptionReason = "Could not resume recording. No valid microphone is available."
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
            AppLog.event("audio", "Audio session interrupted — type=began prevState=\(state)")
            stateBeforeInterruption = state
            if state == .recording {
                state = .interrupted
                audioInterruptionReason = "Recording paused due to interruption (phone call, alarm, etc.)."
                timerTask?.cancel()
                // Close the current segment now so the manifest records the
                // actual audio end time — not the wall-clock time including the gap.
                if let closed = fileWriter.closeCurrentSegment() {
                    onSegmentClosed?(closed)
                }
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            if options?.contains(.shouldResume) == true,
               stateBeforeInterruption == .recording || stateBeforeInterruption == .paused {
                AppLog.audio.info("Audio interruption ended — rebuilding with new segment")
                let shouldRecord = stateBeforeInterruption == .recording
                Task { @MainActor in
                    _ = await rebuildForNewRoute(reason: "interruptionEnded", resumeRecording: shouldRecord)
                }
            } else if state == .interrupted {
                AppLog.audio.info("Audio interruption ended without shouldResume — paused")
                audioInterruptionReason = "Interruption ended. Recording paused."
                state = .paused
            }
            stateBeforeInterruption = nil
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

        // Input lost while recording or paused
        guard inputAvailable else {
            if state == .recording || state == .paused {
                // Remember intent so we auto-resume when input returns
                self.shouldResumeAfterRouteRecovery = (state == .recording)
                stateBeforeInterruption = state

                state = .interrupted
                audioInterruptionReason = "Microphone disconnected. Waiting for input…"
                timerTask?.cancel()

                // Close current segment so manifest metadata is accurate
                if let closed = fileWriter.closeCurrentSegment() {
                    onSegmentClosed?(closed)
                }
                AppLog.audio.info("Input lost — shouldResume=\(self.shouldResumeAfterRouteRecovery)")
            }
            return
        }

        // Input returned while interrupted — auto-recover
        if state == .interrupted, currentMeetingId != nil {
            AppLog.audio.info("Input recovered — auto-rebuilding (shouldResume=\(self.shouldResumeAfterRouteRecovery))")
            let result = await rebuildForNewRoute(reason: "routeRecovered", resumeRecording: self.shouldResumeAfterRouteRecovery)
            self.shouldResumeAfterRouteRecovery = false
            if case .failed(let reason) = result {
                AppLog.audio.error("Auto-recovery failed: \(reason)")
            }
            return
        }

        // Input changed while recording or paused — rebuild with new route
        let wasRecording = state == .recording
        guard wasRecording || state == .paused else {
            currentInputPortName = portName
            return
        }

        let result = await rebuildForNewRoute(reason: String(reason.rawValue), resumeRecording: wasRecording)
        currentInputPortName = portName
        AppLog.audio.info("Rebuilt for new route: \(portName)")
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        AppLog.error("audio", "Media services reset — rebuilding with new segment")
        if state == .recording || state == .paused {
            let wasRecording = state == .recording
            Task { @MainActor in
                _ = await rebuildForNewRoute(reason: "mediaServicesReset", resumeRecording: wasRecording)
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
