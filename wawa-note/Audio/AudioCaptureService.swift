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
    case validatingRoute           // engine started, waiting for first audio buffer
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

    /// Active probe that periodically checks for usable input when in
    /// .waitingForUsableInput. Prevents the state from becoming a black hole
    /// when route change notifications don't fire or fire incompletely.
    private var waitingInputProbeTask: Task<Void, Never>?

    private let audioLevelLock = NSLock()
    private nonisolated(unsafe) var rawAudioLevel: Float = 0.0

    /// Timestamp of the last audio buffer received from the tap.
    /// Set in the tap callback (real-time thread). Used to validate
    /// that a new route is actually delivering audio.
    private nonisolated(unsafe) var lastBufferReceivedAt: Date = .distantPast

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
                guard let self, self.recordingIntent != .userStopped, self.state != .idle, self.state != .stopped else { return }

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
                _ = self.checkpointCurrentSegment(reason: "writeFailure")
                self.transition(to: .failedFatal(reason), reason: "writeFailure")
                self.audioInterruptionReason = reason
                AppLog.error("audio", "Recording terminated by write failure: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        removeAudioNotificationObservers()
    }

    // MARK: - Segment checkpoint (data safety)

    /// Checkpoint the current segment BEFORE attempting any route change.
    /// The segment recorded up to this point belongs to the user — it must
    /// survive regardless of whether Bluetooth/route recovery succeeds.
    ///
    /// 1. Closes the current audio file.
    /// 2. Notifies the coordinator to update the manifest immediately.
    /// 3. Verifies the file exists on disk with size > 0.
    ///
    /// - Returns: ClosedSegmentInfo if checkpoint succeeded, nil if no segment was open.
    @discardableResult
    private func checkpointCurrentSegment(reason: String) -> ClosedSegmentInfo? {
        guard let closed = fileWriter.closeCurrentSegment() else {
            AppLog.audio.info("checkpoint: no open segment to close — \(reason)")
            return nil
        }

        // Verify the file exists and has data, if we have a meeting ID
        if let mid = currentMeetingId {
            let store = FileArtifactStore()
            let fileURL = store.segmentURL(for: mid, fileName: closed.fileName)
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            let size = exists ? (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0 : 0
            AppLog.audio.info("checkpoint: segment \(closed.index) \(closed.fileName) size=\(size) exists=\(exists) — \(reason)")
        } else {
            AppLog.audio.info("checkpoint: segment \(closed.index) \(closed.fileName) — \(reason)")
        }

        // Notify coordinator immediately so the manifest is persisted NOW,
        // before any route change attempt can interfere.
        onSegmentClosed?(closed)

        return closed
    }

    // MARK: - State machine

    /// Single point of state mutation. Every state change goes through here.
    private func transition(to newState: AudioCaptureState, reason: String) {
        let oldState = state
        state = newState
        AppLog.audio.info("State: \(String(describing: oldState)) → \(String(describing: newState)) — \(reason)")

        // Start/stop the waiting-input probe based on state
        if newState == .waitingForUsableInput {
            startWaitingInputProbe()
        } else if oldState == .waitingForUsableInput {
            stopWaitingInputProbe()
        }
    }

    /// Probes for usable input every 1-2s while in .waitingForUsableInput.
    /// If builtInMic is available, automatically triggers recovery.
    /// Route change notifications are NOT sufficient — Bluetooth transitions
    /// may not fire new notifications when already in a waiting state.
    private func startWaitingInputProbe() {
        stopWaitingInputProbe()
        waitingInputProbeTask = Task { [weak self] in
            var backoff = 0
            while !Task.isCancelled, let self {
                let delay = backoff < 2 ? 1_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: UInt64(delay))

                guard !Task.isCancelled,
                      self.state == .waitingForUsableInput,
                      self.recordingIntent == .userWantsRecording,
                      self.currentMeetingId != nil else { break }

                // Re-read session state — things may have changed
                let hasInput = self.sessionManager.isInputAvailable
                let hasBuiltInMic = self.sessionManager.session.availableInputs?.contains { $0.portType == .builtInMic } ?? false

                AppLog.audio.info("Waiting probe: input=\(hasInput) builtInMic=\(hasBuiltInMic) backoff=\(backoff)")

                if hasInput && hasBuiltInMic {
                    // Built-in mic is available — attempt recovery
                    await self.forceBuiltInMicRecovery()
                    // If recovery succeeded, we're out of waiting → probe stops naturally
                    if self.state != .waitingForUsableInput { break }
                    backoff += 1
                } else {
                    backoff = 0  // Reset backoff — still waiting for any input
                }
            }
        }
    }

    private func stopWaitingInputProbe() {
        waitingInputProbeTask?.cancel()
        waitingInputProbeTask = nil
    }

    /// Atomically commit a recovered route to `.recording`. Validates all
    /// preconditions before transitioning. This is the ONLY path that sets
    /// `.recording` from a route recovery — never set it directly.
    private func commitRecoveredRouteToRecording(generation: UUID, reason: String) -> Bool {
        guard generation == routeRecoveryGeneration else {
            AppLog.audio.info("commitRecoveredRouteToRecording: generation mismatch — cancelled")
            return false
        }
        guard recordingIntent == .userWantsRecording else {
            AppLog.audio.info("commitRecoveredRouteToRecording: intent is not userWantsRecording")
            return false
        }
        guard self.engine.isRunning else {
            AppLog.audio.info("commitRecoveredRouteToRecording: engine is not running")
            return false
        }
        guard currentMeetingId != nil else {
            AppLog.audio.info("commitRecoveredRouteToRecording: no current meeting")
            return false
        }
        // All checks passed — commit
        transition(to: .recording, reason: reason)
        startTimer()
        audioInterruptionReason = nil
        currentInputPortName = sessionManager.currentInputPortName
        let port = currentInputPortName
        AppLog.audio.info("Route committed to recording: \(port)")
        return true
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
        switch state {
        case .recording:
            // Normal pause — engine stays alive, tap stops writing.
            transition(to: .pausedByUser, reason: "user paused")
            recordingIntent = .userPaused
            timerTask?.cancel()
            AppLog.audio.info("Recording paused (engine kept alive)")

        case .reconfiguringRoute, .validatingRoute:
            // User paused during route switch — invalidate recovery, stay paused.
            routeRecoveryGeneration = UUID()
            transition(to: .pausedByUser, reason: "user paused during route switch")
            recordingIntent = .userPaused
            AppLog.audio.info("Recording paused — route switch cancelled")

        case .waitingForUsableInput:
            // User paused while waiting for mic.
            stopWaitingInputProbe()
            transition(to: .pausedByUser, reason: "user paused while waiting for mic")
            recordingIntent = .userPaused
            routeRecoveryGeneration = UUID()
            AppLog.audio.info("Recording paused — waiting cancelled")

        case .interruptedBySystem:
            // User explicitly paused during system interruption.
            transition(to: .pausedByUser, reason: "user paused during system interruption")
            recordingIntent = .userPaused
            AppLog.audio.info("Recording paused (system interruption overridden)")

        default:
            AppLog.audio.info("pauseRecording ignored — state not active")
            return
        }
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

    /// Force-finish from ANY state. Does NOT depend on Bluetooth, engine,
    /// recovery tasks, or microphone state. Always works on first call.
    /// Preserves already-committed valid segments via the coordinator.
    func forceFinish() {
        // 1. Kill all async recovery tasks immediately
        routeChangeTask?.cancel()
        routeChangeTask = nil
        stopWaitingInputProbe()
        routeRecoveryGeneration = UUID()

        // 2. Mark intent as stopped — no recovery can resurrect
        recordingIntent = .userStopped

        // 3. Remove all observers
        removeAudioNotificationObservers()

        // 4. Stop timer
        timerTask?.cancel()
        timerTask = nil
        levelMonitorTask?.cancel()

        // 5. Try to stop engine/tap safely — don't crash if already broken
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? sessionManager.deactivate()

        // 6. Close any open segment
        fileWriter.finishRecording()

        // 7. Final transition
        transition(to: .stopped, reason: "forceFinish")
        audioLevel = 0.0
        elapsedTime = 0.0
        recordingStartTime = nil
        currentInputPortName = ""
        currentMeetingId = nil
        stateBeforeSystemInterruption = nil
        AppLog.audio.info("Recording force-finished")
    }

    func stopRecording() {
        forceFinish()
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
            self.lastBufferReceivedAt = Date()  // Track for route validation
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

    /// Clean stop + fresh start for a new audio route. Mirrors startRecording's
    /// proven pattern: new engine, no prior deactivate, configure directly.
    @discardableResult
    private func restartCaptureForNewRoute(reason: String, resumeRecording: Bool, generation: UUID) async -> AudioRebuildResult {
        transition(to: .reconfiguringRoute, reason: "restart capture: \(reason)")
        timerTask?.cancel()

        // 1. Checkpoint the current segment BEFORE touching anything else.
        _ = checkpointCurrentSegment(reason: reason)

        // 2. Clean stop: remove tap, stop engine, release engine.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        guard let meetingId = currentMeetingId else {
            audioInterruptionReason = "Internal error."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        // 3. Return audio resources to the system BEFORE creating anything new.
        //    Deactivate the session, let the system settle, then reconfigure
        //    from a completely clean state — exactly like startRecording.
        try? sessionManager.deactivate()
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms for system to settle

        // 4. Now create a fresh engine on a clean session.
        engine = AVAudioEngine()

        do {
            try sessionManager.configureForRecording()
        } catch {
            AppLog.error("audio", "restartCapture: session configure failed: \(error)")
            audioInterruptionReason = "Could not configure audio."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        guard sessionManager.isInputAvailable else {
            audioInterruptionReason = "No microphone available."
            transition(to: .waitingForUsableInput, reason: "no input after restart")
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        // 5. Open new segment with format matching the new route.
        let sessionRate = sessionManager.sampleRate
        let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false)!

        let closedInfo: ClosedSegmentInfo?
        do {
            // The old segment was already closed by checkpointCurrentSegment.
            // rotateToNewSegment will close (nil), increment index, and open new.
            closedInfo = try fileWriter.rotateToNewSegment(meetingId: meetingId, format: hwFmt)
        } catch {
            AppLog.error("audio", "restartCapture: rotateToNewSegment failed: \(error)")
            audioInterruptionReason = "Could not create audio segment."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)

        // 6. Install tap, prepare, start — identical to startRecording.
        installTap()
        engine.prepare()

        var engineStartSucceeded = false
        for attempt in 0...2 {
            do {
                try engine.start()
                engineStartSucceeded = true
                break
            } catch {
                AppLog.error("audio", "restartCapture: engine start attempt \(attempt+1) failed: \(error.localizedDescription)")
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    engine.reset()
                    engine.prepare()
                }
            }
        }

        guard generation == routeRecoveryGeneration else {
            fileWriter.closeCurrentSegment()
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        if !engineStartSucceeded {
            audioInterruptionReason = "Could not start audio with this microphone."
            fileWriter.closeCurrentSegment()
            if let closed = closedInfo { onSegmentClosed?(closed) }
            try? sessionManager.deactivate()
            transition(to: .waitingForUsableInput, reason: "engine start failed")
            return .engineFailed(NSError(domain: "Audio", code: -1), takeRouteSnapshot(reason: reason))
        }

        // 7. Quick validation — wait for first buffer
        transition(to: .validatingRoute, reason: "validating: \(reason)")
        let bufferCheckStart = lastBufferReceivedAt
        for _ in 0..<20 where lastBufferReceivedAt <= bufferCheckStart {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard generation == routeRecoveryGeneration else {
            fileWriter.closeCurrentSegment()
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        if lastBufferReceivedAt > bufferCheckStart {
            let segment = RecordingSegment(
                id: UUID(), index: segIndex, fileName: segFileName, startedAt: Date(),
                inputPortName: sessionManager.currentInputPortName,
                inputPortType: sessionManager.bestAvailableInput?.portType.rawValue ?? "unknown",
                routeChangeReason: reason, sampleRate: hwFmt.sampleRate
            )
            onSegmentCreated?(closedInfo, segment)
            currentInputPortName = sessionManager.currentInputPortName
            audioInterruptionReason = nil
            let snap = takeRouteSnapshot(reason: reason)

            if resumeRecording, recordingIntent == .userWantsRecording {
                _ = commitRecoveredRouteToRecording(generation: generation, reason: "capture restarted: \(reason)")
                return .resumed(snap)
            } else {
                transition(to: .pausedByUser, reason: "capture restarted (paused)")
                return .paused(snap)
            }
        }

        // No buffers — discard empty segment, wait.
        fileWriter.closeCurrentSegment()
        if let closed = closedInfo { onSegmentClosed?(closed) }
        try? sessionManager.deactivate()
        audioInterruptionReason = "Microphone not delivering audio. Waiting…"
        transition(to: .waitingForUsableInput, reason: "validation failed")
        return .noUsableInput(takeRouteSnapshot(reason: reason))
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

    /// Force recovery using the built-in iPhone microphone.
    /// Explicitly selects builtInMic and restarts capture from scratch.
    /// Accepts any non-terminal state — the user wants to recover NOW.
    func forceBuiltInMicRecovery() async {
        let isFailed: Bool = if case .failedFatal = state { true } else { false }
        guard state != .idle, state != .stopped, !isFailed else {
            AppLog.audio.info("forceBuiltInMicRecovery skipped")
            return
        }
        guard let meetingId = currentMeetingId else { return }

        AppLog.audio.info("Force built-in mic recovery — beginning")

        // Cancel any in-progress recovery
        routeRecoveryGeneration = UUID()
        let gen = routeRecoveryGeneration

        // Clean stop — release everything before creating new
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? sessionManager.deactivate()
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms settle

        // Fresh engine on clean session
        engine = AVAudioEngine()
        try? sessionManager.configureForRecording()

        // Force select built-in mic
        if let builtIn = sessionManager.session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? sessionManager.session.setPreferredInput(builtIn)
            AppLog.audio.info("Forced built-in mic: \(builtIn.portName)")
        }

        guard sessionManager.isInputAvailable else {
            audioInterruptionReason = "iPhone microphone not available."
            transition(to: .waitingForUsableInput, reason: "built-in mic not available")
            return
        }

        // Open new segment
        let sessionRate = sessionManager.sampleRate
        let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false)!
        let closedInfo = try? fileWriter.rotateToNewSegment(meetingId: meetingId, format: hwFmt)
        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)

        // Start engine
        installTap()
        engine.prepare()
        var started = false
        for attempt in 0...2 {
            do { try engine.start(); started = true; break }
            catch {
                if attempt < 2 { try? await Task.sleep(nanoseconds: 300_000_000); engine.reset(); engine.prepare() }
            }
        }

        guard started else {
            fileWriter.closeCurrentSegment()
            audioInterruptionReason = "Could not start iPhone microphone."
            transition(to: .waitingForUsableInput, reason: "built-in mic engine failed")
            return
        }

        // Validate
        transition(to: .validatingRoute, reason: "validating built-in mic")
        let bufStart = lastBufferReceivedAt
        for _ in 0..<20 where lastBufferReceivedAt <= bufStart {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard lastBufferReceivedAt > bufStart else {
            fileWriter.closeCurrentSegment()
            audioInterruptionReason = "iPhone microphone not delivering audio."
            transition(to: .waitingForUsableInput, reason: "built-in mic validation failed")
            return
        }

        // Commit
        let segment = RecordingSegment(
            id: UUID(), index: segIndex, fileName: segFileName, startedAt: Date(),
            inputPortName: sessionManager.currentInputPortName,
            inputPortType: "builtInMic",
            routeChangeReason: "forceBuiltInMic", sampleRate: hwFmt.sampleRate
        )
        onSegmentCreated?(closedInfo, segment)
        currentInputPortName = sessionManager.currentInputPortName
        audioInterruptionReason = nil
        _ = commitRecoveredRouteToRecording(generation: gen, reason: "forced built-in mic")
    }

    /// Attempt to recover from an interrupted/waiting state.
    /// - Parameter forceRecording: if true, always resume as .recording.
    func attemptResume(forceRecording: Bool = false) async {
        guard state == .interruptedBySystem || state == .waitingForUsableInput else { return }
        let shouldRecord = forceRecording || recordingIntent == .userWantsRecording
        let gen = routeRecoveryGeneration
        _ = await restartCaptureForNewRoute(reason: forceRecording ? "manualResume" : "recovery", resumeRecording: shouldRecord, generation: gen)
        // restartCaptureForNewRoute handles all state transitions internally
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
                _ = checkpointCurrentSegment(reason: "systemInterruptionBegan")
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            if options?.contains(.shouldResume) == true,
               recordingIntent == .userWantsRecording {
                AppLog.audio.info("System interruption ended — rebuilding")
                let gen = routeRecoveryGeneration
                Task { @MainActor in
                    _ = await restartCaptureForNewRoute(reason: "interruptionEnded", resumeRecording: true, generation: gen)
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

        // Input lost while recording or user-paused → checkpoint and wait
        guard inputAvailable else {
            if recordingIntent == .userWantsRecording || recordingIntent == .userPaused {
                transition(to: .waitingForUsableInput, reason: "input lost")
                audioInterruptionReason = "Microphone disconnected. Waiting for input…"
                timerTask?.cancel()
                _ = checkpointCurrentSegment(reason: "inputLost")
            }
            return
        }

        // Only act if we have an active recording session
        guard recordingIntent == .userWantsRecording || recordingIntent == .userPaused else {
            currentInputPortName = portName
            return
        }

        // Bluetooth disconnected → force fallback to built-in mic.
        // The iPhone mic is always available and reliable. Don't wait
        // for bestAvailableInput — it may still prefer the stale Bluetooth route.
        if reason == .oldDeviceUnavailable {
            if recordingIntent == .userWantsRecording {
                AppLog.audio.info("Bluetooth disconnected — forcing built-in mic fallback")
                await forceBuiltInMicRecovery()
            }
            currentInputPortName = sessionManager.currentInputPortName
            return
        }

        // Input returned or route changed — restart capture cleanly
        let resume = recordingIntent == .userWantsRecording
        let gen = routeRecoveryGeneration
        _ = await restartCaptureForNewRoute(reason: String(reason.rawValue), resumeRecording: resume, generation: gen)
        currentInputPortName = portName
        AppLog.audio.info("Route change handled: \(portName)")
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        AppLog.error("audio", "Media services reset — restarting capture")
        if recordingIntent == .userWantsRecording || recordingIntent == .userPaused {
            let resume = recordingIntent == .userWantsRecording
            let gen = routeRecoveryGeneration
            Task { @MainActor in
                _ = await restartCaptureForNewRoute(reason: "mediaServicesReset", resumeRecording: resume, generation: gen)
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
