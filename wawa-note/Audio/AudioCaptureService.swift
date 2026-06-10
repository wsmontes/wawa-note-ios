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
    private func rebuildForNewRoute(reason: String, resumeRecording: Bool) {
        let prevState = state
        state = .interrupted  // Prevent tap from writing during transition
        timerTask?.cancel()

        // 1. Remove tap, stop engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // 2. Reconfigure session BEFORE rotating segments (session changes
        //    sample rate, which determines file format)
        try? sessionManager.deactivate()
        do {
            try sessionManager.configureForRecording()
        } catch {
            AppLog.error("audio", "rebuildForNewRoute: session reconfigure failed: \(error)")
            audioInterruptionReason = "Could not configure audio."
            return
        }

        // 3. Get format BEFORE engine.reset() destroys it. Use session sampleRate
        //    as source of truth — reflects the actual hardware route.
        let sessionRate = sessionManager.sampleRate
        let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false)!
        engine.reset()

        guard let meetingId = currentMeetingId else {
            audioInterruptionReason = "Internal error."
            return
        }

        // 4. Atomically rotate to new segment — close old + open new.
        //    The writer owns fileName, index, and extension decisions.
        let closedInfo: ClosedSegmentInfo?
        do {
            closedInfo = try fileWriter.rotateToNewSegment(meetingId: meetingId, format: hwFmt)
        } catch {
            AppLog.error("audio", "rebuildForNewRoute: rotateToNewSegment failed: \(error)")
            audioInterruptionReason = "Could not create audio segment."
            try? sessionManager.deactivate()
            return
        }

        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)

        // 5. Start engine — file is already open
        installTap()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AppLog.error("audio", "rebuildForNewRoute: engine start failed: \(error)")
            audioInterruptionReason = "Could not start audio."
            fileWriter.closeCurrentSegment()  // Clean up unused segment
            try? sessionManager.deactivate()
            return
        }

        // 6. Emit new segment and restore state
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
        AppLog.audio.info("Rebuilt for new route: \(self.sessionManager.currentInputPortName) segment=\(segIndex)")
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

    func attemptResume() {
        guard state == .interrupted else { return }
        let shouldRecord = stateBeforeInterruption == .recording
        rebuildForNewRoute(reason: "interruptionEnded", resumeRecording: shouldRecord)
        audioInterruptionReason = state == .interrupted ? "Could not resume after interruption" : nil
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
                rebuildForNewRoute(reason: "interruptionEnded", resumeRecording: shouldRecord)
                audioInterruptionReason = state == .interrupted ? "Could not resume after interruption" : nil
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
    /// With segmented recording, this is safe: the segment closes before rebuild
    /// and a new segment opens after. The logical recording is uninterrupted.
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        let newPort = sessionManager.currentInputPortName
        AppLog.audio.info("Audio route changed: reason=\(reason.rawValue) port=\(newPort)")

        // No input available → pause
        guard sessionManager.isInputAvailable else {
            if state == .recording || state == .paused {
                state = .interrupted
                audioInterruptionReason = "No microphone available."
                timerTask?.cancel()
            }
            return
        }

        // Rebuild if recording OR paused (engine is alive in both states)
        let wasRecording = state == .recording
        guard wasRecording || state == .paused else {
            currentInputPortName = newPort
            return
        }

        rebuildForNewRoute(reason: String(reason.rawValue), resumeRecording: wasRecording)
        currentInputPortName = newPort
        AppLog.audio.info("Rebuilt for new route: \(newPort)")
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        AppLog.error("audio", "Media services reset — rebuilding with new segment")
        if state == .recording || state == .paused {
            rebuildForNewRoute(reason: "mediaServicesReset", resumeRecording: state == .recording)
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
