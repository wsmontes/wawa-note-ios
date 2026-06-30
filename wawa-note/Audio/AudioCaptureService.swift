import AVFoundation
import Accelerate
import OSLog

// Related JIRA: KAN-5, KAN-14, KAN-78

// MARK: - State

enum AudioCaptureState: Equatable {
    case idle
    case recording
    case paused
    case stopped
}

// MARK: - AudioCaptureService

/// Audio capture service — microphone → file.
/// No live transcription. Transcription happens post-recording via
/// ContentExtractionService → TranscriptionEngine.
/// All public mutating methods MUST be called from @MainActor (RecordingCoordinator).
/// @Published writes are safe: rebuild tasks use Task { @MainActor }, audio tap
/// callback only writes to lock-protected raw values (levelLock + silenceLock).
/// KAN-418: Cannot mark class @MainActor because real-time audio I/O callbacks
/// need non-isolated access for lock-protected samples.
final class AudioCaptureService: ObservableObject, @unchecked Sendable {

    // MARK: Published

    @Published private(set) var state: AudioCaptureState = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var currentInputPortName: String = ""
    @Published private(set) var currentInputPortIcon: String = "mic.fill"
    /// Write-queue depth from AudioFileWriter. Values > 5 indicate disk
    /// saturation — the coordinator should warn the user proactively.
    var queueDepth: Int32 { fileWriter.queueDepth }
    /// Audio format metadata of the active recording — captured before
    /// session deactivation so it's available during item finalization.
    var captureSampleRate: Double { sessionManager.sampleRate }
    var captureChannelCount: Int { 1 }  // Always mono in current implementation
    var captureInputPortType: String { sessionManager.bestAvailableInput?.portType.rawValue ?? "unknown" }

    /// True when audio level has been below the silence threshold for >60 seconds.
    /// The UI should show a "Silence detected" indicator so the user can check
    /// if the mic is muted or the recording was left running accidentally.
    @Published private(set) var silenceDetected: Bool = false

    @Published private(set) var audioInterruptionReason: String?

    // MARK: Callbacks

    var onSegmentCreated: ((_ closedInfo: ClosedSegmentInfo?, _ newSegment: RecordingSegment) -> Void)?
    var onSegmentClosed: ((_ closedInfo: ClosedSegmentInfo) -> Void)?
    var nextSegmentIndexProvider: (() -> Int)?

    // MARK: Public

    let fileWriter: AudioFileWriter
    var outputFileURL: URL? { fileWriter.currentFileURL }

    /// Force the audio session to use the built-in microphone, abandoning Bluetooth/HFP.
    /// Used by RecordingCoordinator's pre-flight retry as a last-resort fallback
    /// when the current route keeps failing.
    func forceBuiltInMic() {
        guard
            let builtIn = sessionManager.session.availableInputs?.first(where: { $0.portType == .builtInMic })
                ?? sessionManager.session.currentRoute.inputs.first(where: { $0.portType == .builtInMic })
        else {
            AppLog.audio.warning("forceBuiltInMic: no built-in mic available")
            return
        }
        do {
            try sessionManager.session.setPreferredInput(builtIn)
            AppLog.audio.info("forceBuiltInMic: switched to \(builtIn.portName)")
        } catch {
            AppLog.audio.warning("forceBuiltInMic: setPreferredInput failed — \(error.localizedDescription)")
        }
    }

    // MARK: Internal

    private var engine: AVAudioEngine?
    let sessionManager = AudioSessionManager()
    private var timerTask: Task<Void, Never>?
    private var recordingStartTime: Date?
    private var interruptionBeganAt: Date?  // Tracks when the current interruption started
    private var isRecoveringFromInterruption = false  // Suppress route changes during recovery
    private var currentMeetingId: UUID?
    private var observers: [NSObjectProtocol] = []
    private var levelSmoothTask: Task<Void, Never>?
    // Route change debounce — replaces rebuildTask?.cancel() pattern.
    // When multiple route change notifications arrive in rapid succession
    // (AirPods emit 3 in <100ms: engineConfigChange + oldDeviceUnavailable +
    // newDeviceAvailable), we pause immediately on the first one, then debounce
    // subsequent ones and rebuild once after the route settles.
    private var isRebuilding = false
    private var pendingRouteChange = false
    private var routeChangeDebounceTask: Task<Void, Never>?
    private var routeChangeDebounceStart: Date?
    private var rawLevel: Float = 0
    private let levelLock = NSLock()

    // MARK: Constants

    private static let captureBufferSize: AVAudioFrameCount = 1024
    private static let timerInterval: TimeInterval = 0.1

    // MARK: Init

    init(fileWriter: AudioFileWriter = AudioFileWriter()) {
        self.fileWriter = fileWriter
        // Propagate write failures (e.g., disk full) — fatal, not recoverable.
        fileWriter.onWriteFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.state == .recording || self.state == .paused else { return }

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
                self.stopRecording()
                AppLog.error("audio", "Recording terminated by write failure: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Recording lifecycle

    func startRecording(meetingId: UUID) async throws {
        guard state == .idle else {
            AppLog.error("audio", "startRecording: invalid state \(state)")
            throw AudioCaptureError.engineStartFailed
        }

        let granted = await sessionManager.requestPermission()
        guard granted else { throw AudioCaptureError.permissionDenied }

        guard AudioSessionManager.hasMinimumDiskSpace() else {
            throw AudioCaptureError.diskFull
        }

        try sessionManager.configureForRecording()

        let baseRate = sessionManager.sampleRate > 0 ? sessionManager.sampleRate : 44100
        guard
            let recordFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: baseRate, channels: 1, interleaved: false
            )
        else { throw AudioCaptureError.engineStartFailed }

        AppLog.audio.info("Recording format: \(Int(baseRate))Hz PCM WAV")

        currentMeetingId = meetingId
        try fileWriter.startRecording(format: recordFormat, meetingId: meetingId)

        // Initial segment is created synchronously by the coordinator (placeholder).
        // onSegmentCreated/onSegmentClosed handle route-change segments during recording.

        // Fresh engine
        let engine = AVAudioEngine()
        self.engine = engine
        engine.reset()

        // Audio tap — level + write to file only
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) {
            [weak self] buffer, _ in
            guard let self else { return }

            self.updateAudioLevel(from: buffer)

            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
            self.fileWriter.write(samples: samples, frameLength: n, format: buffer.format)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Clean up everything created before the throw so the service
            // returns to a clean idle state. The coordinator already rolls
            // back the model item — we must roll back our internal resources.
            inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            self.engine = nil
            _ = fileWriter.finishRecording()
            currentMeetingId = nil
            throw error
        }

        state = .recording
        currentInputPortName = sessionManager.currentInputPortName
        currentInputPortIcon = sessionManager.currentInputIcon
        recordingStartTime = Date()
        startTimer()
        startLevelSmoothing()
        observeNotifications()

        AppLog.event("audio", "Recording started — input: \(currentInputPortName)")
    }

    func pauseRecording() {
        guard state == .recording else { return }
        engine?.pause()
        state = .paused
        stopTimer()
    }

    func resumeRecording() throws {
        guard state == .paused else { return }
        try engine?.start()
        state = .recording
        startTimer()
    }

    func stopRecording() {
        let wasRecording = state == .recording || state == .paused

        stopTimer()
        stopLevelSmoothing()
        removeObservers()

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        self.engine = nil

        let closed = fileWriter.finishRecording()
        if let closed {
            onSegmentClosed?(closed)
        }

        // Deactivate audio session so other apps can use the microphone.
        // Failing to deactivate leaks the audio hardware: battery drain,
        // other apps blocked, and the next recording may fail with
        // AVAudioSessionErrorCode.resourceNotAvailable.
        try? sessionManager.deactivate()

        state = .stopped
        audioLevel = 0
        elapsedTime = 0
        recordingStartTime = nil
        currentMeetingId = nil
        currentInputPortName = ""
        currentInputPortIcon = "mic.fill"
        silenceDetected = false
        audioInterruptionReason = nil

        if wasRecording { AppLog.event("audio", "Recording stopped") }
    }

    func resetToIdle() {
        guard state == .stopped else { return }
        state = .idle
    }

    // MARK: - Audio level

    /// Adaptive gain factor for audio level normalization. Slowly adjusts to
    /// target ~0.7 peak for normal speech, clamped between 1.0x and 8.0x.
    /// Bluetooth HFP (8kHz) and USB mics have widely different gain profiles
    /// — a fixed 4.0x multiplier produces either near-silence or constant
    /// clipping for non-built-in inputs.
    private var adaptiveGain: Float = 4.0
    private var silenceConsecutiveSeconds: Double = 0
    /// Protects adaptiveGain and silenceConsecutiveSeconds accessed from both
    /// the real-time audio I/O thread and the main actor (silenceDetected).
    private let silenceLock = NSLock()

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        var peak: Float = 0
        vDSP_maxmgv(ch[0], 1, &peak, vDSP_Length(buffer.frameLength))

        let normalized = min(1.0, peak * adaptiveGain)

        // Adaptive gain: slowly move toward target peak of 0.7 for normal speech.
        // Adjusts by ±2% per buffer (~90ms convergence) — fast enough to adapt
        // within a few seconds of speech, slow enough to not oscillate on pauses.
        // Protected by silenceLock (real-time audio thread + main actor access).
        silenceLock.lock()
        if normalized > 0.01 && normalized < 1.0 {
            if normalized > 0.85 {
                adaptiveGain = max(1.0, adaptiveGain * 0.98)  // Reduce gain (too hot)
            } else if normalized < 0.25 && peak > 0.001 {
                adaptiveGain = min(8.0, adaptiveGain * 1.02)  // Boost gain (too quiet)
            }
        }

        // Silence detection: track consecutive seconds below threshold.
        // After 60s of silence, set silenceDetected for UI indication.
        if normalized < 0.015 {
            self.silenceConsecutiveSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        } else {
            if self.silenceConsecutiveSeconds >= 60 {
                AppLog.audio.info("Silence ended after \(self.silenceConsecutiveSeconds)s — was the mic muted?")
            }
            self.silenceConsecutiveSeconds = 0
        }
        let isSilent = self.silenceConsecutiveSeconds >= 60.0
        silenceLock.unlock()

        levelLock.withLock {
            rawLevel = normalized
        }
        // Update silenceDetected on main actor (it's @Published)
        if silenceDetected != isSilent {
            DispatchQueue.main.async { [weak self] in
                self?.silenceDetected = isSilent
            }
        }
    }

    private func startLevelSmoothing() {
        levelSmoothTask?.cancel()
        levelSmoothTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 66_000_000)
                guard let self else { return }
                self.audioLevel = self.levelLock.withLock { self.rawLevel }
            }
        }
    }

    private func stopLevelSmoothing() {
        levelSmoothTask?.cancel()
        levelSmoothTask = nil
    }

    // MARK: - Timer

    private var checkpointTask: Task<Void, Never>?

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let start = self?.recordingStartTime {
                    self?.elapsedTime = Date().timeIntervalSince(start)
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.timerInterval * 1_000_000_000))
            }
        }
        // Separate periodic checkpoint: every 5 seconds, write crash recovery data.
        // This ensures that if the app crashes or is force-quit, we can recover
        // the recording on next launch.
        checkpointTask?.cancel()
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let meetingId = self.currentMeetingId else { continue }
                let sampleRate = self.sessionManager.sampleRate > 0 ? self.sessionManager.sampleRate : 44100
                guard
                    let fmt = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
                    )
                else { continue }
                let segIdx = self.fileWriter.segmentIndex
                self.fileWriter.writeCheckpoint(meetingId: meetingId, segmentIndex: segIdx, format: fmt)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let nc = NotificationCenter.default
        let q = OperationQueue.main
        observers.append(
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: q) { [weak self] n in self?.handleInterruption(n) })
        observers.append(
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: q) { [weak self] _ in
                AppLog.audio.warning("Media services were reset — attempting engine rebuild")
                Task { @MainActor [weak self] in
                    await self?.rebuildEngineForCurrentRoute(forceBuiltInMic: true, reason: "mediaServicesReset")
                }
            })

        // Route changes: Bluetooth connect/disconnect, headset plug/unplug, etc.
        // When the route changes during recording, the existing tap may be
        // configured for the old route — close and reopen a segment so the
        // coordinator can track the change, and rebuild the engine if needed.
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: q) { [weak self] n in self?.handleRouteChange(n) })

        // Engine configuration change: iOS may clear taps internally before
        // routeChangeNotification fires (e.g., Bluetooth HFP handoff). The
        // engine is scoped to the current engine instance.
        if let eng = engine {
            observers.append(
                nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng, queue: q) { [weak self] n in
                    // Engine config changes don't carry AVAudioSessionRouteChangeReasonKey.
                    // handleRouteChange handles this — the guard uses optional binding and
                    // falls through to generic debounce path with nil reason.
                    AppLog.audio.info("Engine config change — routing through unified debounce path")
                    self?.handleRouteChange(n)
                })
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func handleInterruption(_ n: Notification) {
        guard let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let t = AVAudioSession.InterruptionType(rawValue: type)
        else { return }
        switch t {
        case .began:
            guard state == .recording else { return }
            engine?.pause()
            state = .paused
            interruptionBeganAt = Date()
            isRecoveringFromInterruption = true
            stopTimer()
        case .ended:
            guard state == .paused else { return }
            // Calculate interruption gap and shift recordingStartTime forward
            // so elapsed time doesn't include the phone call / Siri duration.
            if let beganAt = interruptionBeganAt {
                let gap = Date().timeIntervalSince(beganAt)
                if let start = recordingStartTime {
                    recordingStartTime = start.addingTimeInterval(gap)
                }
                AppLog.audio.info("Interruption gap of \(Int(gap))s subtracted from elapsed time")
            }
            interruptionBeganAt = nil
            if let opt = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                AVAudioSession.InterruptionOptions(rawValue: opt).contains(.shouldResume)
            {
                // Retry engine start asynchronously — audio hardware (modem,
                // Bluetooth SCO link) may need hundreds of ms to release after
                // a phone call ends. A single try? is often insufficient.
                // Suppress route-change rebuilds during recovery to prevent
                // conflicting engine restarts.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRecoveringFromInterruption = true
                    defer { self.isRecoveringFromInterruption = false }
                    for attempt in 0..<3 {
                        do {
                            try self.engine?.start()
                            guard self.state == .paused else { return }
                            self.state = .recording
                            self.startTimer()
                            AppLog.audio.info("Interruption ended — resumed after \(attempt + 1) attempt(s)")
                            return
                        } catch {
                            if attempt < 2 {
                                let delayNs: UInt64 = [300_000_000, 600_000_000][attempt]
                                AppLog.audio.warning("Interruption resume attempt \(attempt + 1) failed — retrying in \(delayNs / 1_000_000)ms")
                                try? await Task.sleep(nanoseconds: delayNs)
                            }
                        }
                    }
                    AppLog.audio.error("Interruption resume failed after 3 attempts — staying paused")
                }
            }
        @unknown default: break
        }
    }

    private func handleRouteChange(_ n: Notification) {
        guard state == .recording || state == .paused else { return }

        // Engine config changes don't carry a RouteChangeReasonKey. Treat them
        // as generic route changes — same debounce + rebuild path applies.
        let reasonValue = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        let reasonLabel = reason.map { "\($0.rawValue)" } ?? "engineConfigurationChange"

        AppLog.audio.info("Route change: \(reasonLabel) — input: \(self.sessionManager.currentInputPortName)")

        // Special case: categoryChange is handled separately — another app
        // stole the audio category. If we can't get it back, stop entirely.
        if reason == .categoryChange {
            if self.sessionManager.session.category != .playAndRecord {
                AppLog.audio.warning("Route change: category changed to \(self.sessionManager.session.category.rawValue) — reconfiguring for recording")
                do {
                    try self.sessionManager.adaptToRouteChange()
                } catch {
                    AppLog.audio.error("Failed to adapt session after category change: \(error.localizedDescription)")
                    self.audioInterruptionReason = "Audio category changed by system."
                    self.stopRecording()
                }
            }
            return
        }

        // All other route change reasons: pause, debounce, rebuild, resume.
        let wasRecording = state == .recording
        engine?.pause()
        state = .paused
        if wasRecording { stopTimer() }
        audioInterruptionReason = interruptionMessage(for: reason)

        // Debounce: reset timer on each new notification so we rebuild
        // once after the route settles. Cap at 5s to prevent runaway.
        routeChangeDebounceTask?.cancel()
        if routeChangeDebounceStart == nil {
            routeChangeDebounceStart = Date()
        }

        if Date().timeIntervalSince(routeChangeDebounceStart!) > 5.0 {
            AppLog.audio.warning("Route change debounce cap reached — forcing rebuild")
            routeChangeDebounceStart = nil
            performRebuild()
            return
        }

        let delay = sessionManager.settleDelayNs  // 750ms BT, 500ms otherwise
        routeChangeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.routeChangeDebounceStart = nil
            await self?.performRebuild()
        }
    }

    /// Human-readable interruption reason for the UI.
    private func interruptionMessage(for reason: AVAudioSession.RouteChangeReason?) -> String {
        guard let reason else { return "Audio engine reconfigured — adapting." }
        switch reason {
        case .newDeviceAvailable: return "Audio device connected — switching."
        case .oldDeviceUnavailable: return "Audio device disconnected — switching input."
        case .override: return "Audio route changed — adapting."
        default: return "Audio route changed."
        }
    }

    // MARK: - Rebuild orchestration

    /// Attempt a rebuild with up to 3 retries. On success, resumes recording.
    /// On total failure, vibrates and stays paused with an error message.
    private func performRebuild() {
        guard !isRebuilding else {
            // Already rebuilding — flag for retry when current one completes.
            pendingRouteChange = true
            return
        }
        isRebuilding = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRebuilding = false }

            let forceOnAttempt = 2  // 0-indexed: attempt 2 = force built-in mic
            let backoffNs: [UInt64] = [0, 500_000_000, 1_000_000_000]

            for attempt in 0..<3 {
                let forceBuiltIn = attempt >= forceOnAttempt
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: backoffNs[attempt])
                }

                let reason = forceBuiltIn ? "routeChange-forceBuiltIn" : "routeChange"
                let success = await self._rebuildEngineForCurrentRoute(
                    forceBuiltInMic: forceBuiltIn, reason: reason
                )

                if success {
                    self.state = .recording
                    self.startTimer()
                    self.audioInterruptionReason = nil
                    AppLog.audio.info("performRebuild: succeeded on attempt \(attempt + 1)")

                    // If another route change arrived while we were rebuilding,
                    // schedule a fresh debounce cycle.
                    if self.pendingRouteChange {
                        self.pendingRouteChange = false
                        self.routeChangeDebounceStart = nil
                        let delay = self.sessionManager.settleDelayNs
                        self.routeChangeDebounceTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: delay)
                            guard !Task.isCancelled else { return }
                            self?.routeChangeDebounceStart = nil
                            await self?.performRebuild()
                        }
                    }
                    return
                }

                AppLog.audio.warning("performRebuild: attempt \(attempt + 1) failed")
            }

            // All 3 attempts failed.
            AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
            self.audioInterruptionReason = "No microphone available"
            AppLog.audio.error("performRebuild: all 3 attempts failed — staying paused")
        }
    }

    // MARK: - Recovery

    /// Force the built-in microphone as the recording input, rebuild the engine,
    /// and resume recording. Used as a last resort when Bluetooth fails.
    func forceBuiltInMicRecovery() async {
        _ = await rebuildEngineForCurrentRoute(forceBuiltInMic: true, reason: "forceBuiltInMic")
    }

    // MARK: - Engine rebuild (shared by route change, recovery, and config change)

    /// Full engine rebuild: checkpoint segment → tear down → reconfigure session →
    /// build new engine → open new segment → resume. Used for route changes and
    /// forced built-in mic recovery. When `forceBuiltInMic` is true, sets the
    /// preferred input to the built-in microphone before building the engine.
    private func rebuildEngineForCurrentRoute(forceBuiltInMic: Bool, reason: String) async -> Bool {
        // Direct call — no more cancellation. performRebuild handles retry.
        await _rebuildEngineForCurrentRoute(forceBuiltInMic: forceBuiltInMic, reason: reason)
    }

    @MainActor
    private func _rebuildEngineForCurrentRoute(forceBuiltInMic: Bool, reason: String) async -> Bool {
        guard state == .recording || state == .paused else {
            AppLog.audio.warning("rebuildEngine(\(reason)): unexpected state \(String(describing: self.state))")
            return false
        }
        guard let meetingId = currentMeetingId else {
            AppLog.audio.error("rebuildEngine(\(reason)): no meetingId — cannot rebuild")
            return false
        }

        AppLog.audio.info("rebuildEngine(\(reason)): starting — forceBuiltInMic=\(forceBuiltInMic)")

        // 1. Checkpoint current segment (preserve audio written so far)
        let closedInfo = fileWriter.closeCurrentSegment()
        if let closed = closedInfo {
            onSegmentClosed?(closed)
            AppLog.audio.info("rebuildEngine(\(reason)): segment \(closed.index) checkpointed — \(closed.fileName) \(closed.fileSize) bytes")
        }

        // 2. Tear down current engine
        if let oldEngine = engine {
            oldEngine.inputNode.removeTap(onBus: 0)
            oldEngine.stop()
            oldEngine.reset()
        }
        self.engine = nil

        // 3. Deactivate and reconfigure session
        try? sessionManager.deactivate()
        // Brief settle — Bluetooth needs time to release hardware
        try? await Task.sleep(nanoseconds: sessionManager.settleDelayNs)
        do {
            try sessionManager.configureForRecording()
        } catch {
            AppLog.audio.error("rebuildEngine(\(reason)): session reconfigure failed — \(error.localizedDescription)")
            return false
        }

        // 4. Optionally force built-in mic
        if forceBuiltInMic {
            if let builtIn = (sessionManager.session.availableInputs ?? []).first(where: { $0.portType == .builtInMic }) {
                do {
                    try sessionManager.session.setPreferredInput(builtIn)
                    AppLog.audio.info("rebuildEngine(\(reason)): forced built-in mic — \(builtIn.portName)")
                } catch {
                    AppLog.audio.warning("rebuildEngine(\(reason)): setPreferredInput failed — \(error.localizedDescription)")
                }
            }
        }

        // 5. Build new engine
        guard buildAndStartEngine(reason: reason) else { return false }

        // 6. Open new segment for the new route
        let nextIndex = nextSegmentIndexProvider?() ?? 0
        let sampleRate = sessionManager.sampleRate > 0 ? sessionManager.sampleRate : 44100
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            )
        else {
            AppLog.audio.error("rebuildEngine(\(reason)): failed to create audio format")
            return false
        }
        do {
            try fileWriter.startNextSegmentForExistingRecording(
                meetingId: meetingId, format: format, manifestNextIndex: nextIndex
            )
        } catch {
            AppLog.audio.error("rebuildEngine(\(reason)): failed to open new segment — \(error.localizedDescription)")
            return false
        }

        // 7. Notify coordinator of new segment
        let portName = sessionManager.currentInputPortName
        let portType = sessionManager.bestAvailableInput?.portType.rawValue ?? "unknown"
        let segment = RecordingSegment(
            id: UUID(), index: nextIndex,
            fileName: fileWriter.currentFileURL?.lastPathComponent ?? "segment-\(nextIndex).wav",
            startedAt: Date(),
            inputPortName: portName,
            inputPortType: portType,
            routeChangeReason: reason,
            sampleRate: sampleRate
        )
        onSegmentCreated?(closedInfo, segment)

        // 8. Commit (caller handles state = .recording and startTimer)
        currentInputPortName = portName
        currentInputPortIcon = sessionManager.currentInputIcon
        guard let engine = self.engine else {
            AppLog.audio.error("rebuildEngine(\(reason)): engine nil after build")
            return false
        }
        reRegisterEngineObserver(for: engine)
        AppLog.event("audio", "rebuildEngine(\(reason)): recording continued on \(portName) (\(portType)) @ \(Int(sampleRate))Hz")
        return true
    }

    /// Build a new AVAudioEngine, install the tap, prepare, and start.
    /// Returns true on success. On failure, cleans up and calls stopRecording().
    @discardableResult
    @MainActor
    private func buildAndStartEngine(reason: String) -> Bool {
        let sampleRate = sessionManager.sampleRate > 0 ? sessionManager.sampleRate : 44100
        let engine = AVAudioEngine()
        self.engine = engine
        engine.reset()

        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.updateAudioLevel(from: buffer)
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
            self.fileWriter.write(samples: samples, frameLength: n, format: buffer.format)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            AppLog.audio.error("buildAndStartEngine(\(reason)): engine start failed — \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            self.engine = nil
            stopRecording()
            return false
        }
        return true
    }

    /// Attempt to resume recording on the current route. If the engine is
    /// already running, this is a no-op. Falls back to forceBuiltInMicRecovery
    /// if the current engine can't be restarted.
    func attemptResume(forceRecording: Bool = false) async {
        guard state == .paused else {
            if forceRecording && (state == .recording || state == .paused) {
                AppLog.audio.warning("attemptResume: forceRecording but already active (state=\(String(describing: self.state)))")
            }
            return
        }

        // First try: simple engine restart on current route
        do {
            try engine?.start()
            state = .recording
            startTimer()
            AppLog.audio.info("attemptResume: resumed on current route")
            return
        } catch {
            AppLog.audio.warning("attemptResume: engine restart failed — \(error.localizedDescription)")
        }

        // Second try: force built-in mic as fallback
        if forceRecording {
            AppLog.audio.info("attemptResume: falling back to built-in mic")
            await forceBuiltInMicRecovery()
        }
    }

    // MARK: - Helpers

    /// Re-register the AVAudioEngineConfigurationChange observer for a new engine
    /// instance. Called after engine replacement in forceBuiltInMicRecovery().
    private func reRegisterEngineObserver(for newEngine: AVAudioEngine) {
        // Unregister ALL current observers from NotificationCenter before
        // clearing the array. Without this, each rebuild leaks the old
        // route/interruption/engine observers, causing duplicate callbacks
        // and overlapping rebuilds that corrupt the recording.
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()

        // Re-register all non-engine-scoped observers
        let q = OperationQueue.main
        observers.append(
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: q) { [weak self] n in self?.handleInterruption(n) })
        observers.append(
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: q) { [weak self] _ in
                AppLog.audio.warning("Media services were reset — attempting engine rebuild")
                Task { @MainActor [weak self] in
                    await self?.rebuildEngineForCurrentRoute(forceBuiltInMic: true, reason: "mediaServicesReset")
                }
            })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: q) { [weak self] n in self?.handleRouteChange(n) })
        // Engine-scoped observer for the new engine
        observers.append(
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: q) { [weak self] n in
                AppLog.audio.info("Engine config change — routing through unified debounce path")
                self?.handleRouteChange(n)
            })
    }
}

// MARK: - Error

enum AudioCaptureError: Error {
    case engineStartFailed
    case permissionDenied
    case diskFull
}
