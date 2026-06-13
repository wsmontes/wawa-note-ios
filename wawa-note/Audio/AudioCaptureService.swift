import AVFoundation
import Accelerate
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

    /// Validates whether a transition from `self` to `target` is legal.
    /// Returns `false` for transitions that should never happen
    /// (e.g. `.stopped → .pausedByUser`, `.idle → .validatingRoute`).
    func canTransition(to target: AudioCaptureState) -> Bool {
        switch (self, target) {
        // idle → recording only
        case (.idle, .recording): return true

        // recording can go to any non-idle except .validatingRoute (needs engine running first)
        case (.recording, .pausedByUser), (.recording, .reconfiguringRoute),
             (.recording, .interruptedBySystem), (.recording, .failedFatal),
             (.recording, .stopped): return true

        // pausedByUser can go to most states
        case (.pausedByUser, .recording), (.pausedByUser, .reconfiguringRoute),
             (.pausedByUser, .interruptedBySystem), (.pausedByUser, .failedFatal),
             (.pausedByUser, .stopped): return true

        // reconfiguringRoute can go to most states (it's a transient hub)
        case (.reconfiguringRoute, .recording), (.reconfiguringRoute, .pausedByUser),
             (.reconfiguringRoute, .validatingRoute), (.reconfiguringRoute, .waitingForUsableInput),
             (.reconfiguringRoute, .interruptedBySystem), (.reconfiguringRoute, .failedFatal),
             (.reconfiguringRoute, .stopped): return true

        // validatingRoute — transient, most outgoing allowed
        case (.validatingRoute, .recording), (.validatingRoute, .pausedByUser),
             (.validatingRoute, .waitingForUsableInput), (.validatingRoute, .interruptedBySystem),
             (.validatingRoute, .failedFatal), (.validatingRoute, .stopped): return true

        // waitingForUsableInput — probe is active, most outgoing allowed
        case (.waitingForUsableInput, .recording), (.waitingForUsableInput, .validatingRoute),
             (.waitingForUsableInput, .pausedByUser), (.waitingForUsableInput, .reconfiguringRoute),
             (.waitingForUsableInput, .interruptedBySystem), (.waitingForUsableInput, .failedFatal),
             (.waitingForUsableInput, .stopped): return true

        // interruptedBySystem — transient, most outgoing allowed
        case (.interruptedBySystem, .recording), (.interruptedBySystem, .pausedByUser),
             (.interruptedBySystem, .reconfiguringRoute), (.interruptedBySystem, .validatingRoute),
             (.interruptedBySystem, .waitingForUsableInput), (.interruptedBySystem, .failedFatal),
             (.interruptedBySystem, .stopped): return true

        // failedFatal is terminal except for explicit stop
        case (.failedFatal, .stopped): return true

        // stopped is truly terminal — no outgoing transitions
        case (.stopped, _): return false

        // Everything else is illegal (e.g. .idle → .validatingRoute, .stopped → .pausedByUser)
        default: return false
        }
    }
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

    /// Called before opening a new segment during route change. The coordinator
    /// provides the next available index from the manifest, which is the source
    /// of truth — NOT the AudioFileWriter's internal _segmentIndex.
    /// Formula: (manifest.segments.map(\.index).max() ?? -1) + 1
    var nextSegmentIndexProvider: (() -> Int)?

    // MARK: - Internal state

    private var timerTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var levelMonitorTask: Task<Void, Never>?
    private var silenceDetectionTask: Task<Void, Never>?
    private var diskSpaceCheckTask: Task<Void, Never>?
    /// Watchdog that force-resets isPhysicalRestartInProgress after a timeout
    /// to prevent permanent deadlock if engine.start() hangs.
    private var restartWatchdogTask: Task<Void, Never>?
    /// Timer that stops the engine after a long pause to save battery.
    /// ~3-5% battery per hour while engine is idling.
    private var pauseEngineTimeoutTask: Task<Void, Never>?
    /// True when the engine was stopped by the pause timeout (not by user stop).
    /// True when the engine was stopped to save battery during a long pause.
    /// The coordinator reads this to update NowPlayingController and UI state.
    private(set) var engineStoppedForPauseTimeout: Bool = false
    /// Duration before idling engine is stopped during pause.
    private static let pauseEngineTimeoutSeconds: UInt64 = 300  // 5 minutes
    private static let silenceThreshold: Float = 0.015
    private static let silenceDurationBeforePause: TimeInterval = 5.0
    @Published private(set) var isAutoPaused: Bool = false
    @Published private(set) var silenceDetected: Bool = false
    private var recordingStartTime: Date?
    /// Accumulated auto-pause duration. Subtracted from elapsed wall-clock
    /// time so the reported duration reflects actual speech, not silence.
    private var totalAutoPausedDuration: TimeInterval = 0
    private var autoPauseStartDate: Date?
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

    /// Invalidates the current route recovery generation, logging the caller
    /// so "recording stopped mysteriously" bugs are easier to trace.
    private func invalidateRouteRecovery(caller: String = #function) {
        let old = routeRecoveryGeneration
        let new = UUID()
        routeRecoveryGeneration = new
        AppLog.audio.info("Route recovery generation invalidated by \(caller): \(old.uuidString.prefix(8)) → \(new.uuidString.prefix(8))")
    }

    /// Arms a watchdog that force-resets isPhysicalRestartInProgress after
    /// `seconds` if no one cancels it. Prevents permanent deadlock when
    /// engine.start() hangs (observed with some Bluetooth adapters).
    private func armRestartWatchdog(seconds: UInt64 = 15) {
        restartWatchdogTask?.cancel()
        restartWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.isPhysicalRestartInProgress else { return }
            AppLog.error("audio", "WATCHDOG: isPhysicalRestartInProgress stuck for \(seconds)s — force-resetting")
            self.isPhysicalRestartInProgress = false
            self.drainPendingRouteChanges()
        }
    }

    private func cancelRestartWatchdog() {
        restartWatchdogTask?.cancel()
        restartWatchdogTask = nil
    }

    /// Debounce task for route change notifications — Bluetooth transitions can fire
    /// multiple notifications in quick succession. We collapse them into one settled
    /// evaluation after 500ms.
    private var routeChangeTask: Task<Void, Never>?

    /// Active probe that periodically checks for usable input when in
    /// .waitingForUsableInput. Prevents the state from becoming a black hole
    /// when route change notifications don't fire or fire incompletely.
    private var waitingInputProbeTask: Task<Void, Never>?

    /// Guards against overlapping physical capture restarts. Only one restart
    /// (route change, forceBuiltInMic, or manual resume) at a time.
    /// Prevents concurrent engine.stop/removeTap/installTap from corrupting
    /// the audio engine state and crashing.
    private var isPhysicalRestartInProgress = false

    /// Task wrapping the current physical restart. Cancel to abort mid-restart
    /// when the user presses Stop/Finish.
    private var physicalRestartTask: Task<Void, Never>?

    /// Deferred route-change reason. When a second settled route change arrives
    /// while a physical restart is already in progress, we store it here instead
    /// of silently dropping it. Drained at the end of restartCaptureForNewRoute.
    /// Queue of route change reasons that arrived while a physical restart
    /// was in progress. Drained in FIFO order when the restart completes.
    /// Using an array instead of a single optional prevents silently dropping
    /// a third route change that arrives before the pending one is drained.
    private var pendingRouteChanges: [AVAudioSession.RouteChangeReason] = []

    /// Tracks whether the audio tap is currently installed on engine.inputNode.
    /// Must be kept in sync with every installTap/removeTap call so we never
    /// call removeTap when no tap is installed (crashes on some iOS versions).
    private var isTapInstalled = false

    private let audioLevelLock = NSLock()
    private nonisolated(unsafe) var rawAudioLevel: Float = 0.0

    /// Timestamp of the last audio buffer received from the tap.
    /// Set in the tap callback (real-time thread). Used to validate
    /// that a new route is actually delivering audio.
    private nonisolated(unsafe) var lastBufferReceivedAt: Date = .distantPast

    /// Dedicated flag for the real-time audio tap callback.
    /// Reading @Published `state` from the audio thread is a data race
    /// (Swift memory model violation). This flag is set atomically from
    /// the main thread alongside every state transition. On ARM64, aligned
    /// word reads are physically atomic — safe for the tap callback.
    /// Set to true in .recording and .validatingRoute; false otherwise.
    /// Also pre-armed true before engine.start() so the first audio buffers
    /// aren't discarded (rolled back on start failure).
    private nonisolated(unsafe) var _isCapturingAudio: Bool = false

    // AudioFileWriter serializes all writes internally — no external write queue needed.

    /// 1024 frames = ~23ms at 44.1kHz (was 8192 = 186ms).
    private static let captureBufferSize: AVAudioFrameCount = 1024
    private static let levelDecayFactor: Float = 0.85
    private static let levelUpdateIntervalNS: UInt64 = 66_000_000  // ~15Hz — visually smooth, low CPU
    private static let timerUpdateInterval: TimeInterval = 0.1
    private static let checkpointInterval: TimeInterval = 5.0
    private static let diskSpaceCheckInterval: TimeInterval = 10.0
    /// Stop recording when free space drops below this threshold (bytes).
    private static let criticalDiskThreshold: Int64 = 5_000_000   // 5 MB
    /// Log a warning when free space drops below this threshold.
    private static let lowDiskWarningThreshold: Int64 = 20_000_000 // 20 MB

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

                self.stopTimer()
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

        // Validate the transition against the allowed matrix. Reject illegal
        // transitions (e.g. .stopped → .pausedByUser) that can only happen
        // through async notification races or bugs.
        guard oldState.canTransition(to: newState) else {
            AppLog.error("audio", "REJECTED illegal state transition: \(String(describing: oldState)) → \(String(describing: newState)) — reason: \(reason)")
            return
        }

        state = newState
        AppLog.audio.info("State: \(String(describing: oldState)) → \(String(describing: newState)) — \(reason)")

        // Keep _isCapturingAudio in sync for the real-time tap callback.
        // The tap reads this flag instead of @Published state (data-race fix).
        // Include .validatingRoute — the engine is running and delivering audio
        // during route validation; discarding it loses up to 4s of audio.
        _isCapturingAudio = (newState == .recording || newState == .validatingRoute)

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
    ///
    /// Caps recovery attempts at 3 to prevent infinite loops that create
    /// empty segment files on disk. After 3 failures, the probe stops and
    /// the user must manually resume or stop.
    private func startWaitingInputProbe() {
        stopWaitingInputProbe()
        waitingInputProbeTask = Task { @MainActor [weak self] in
            var backoff = 0
            var recoveryAttempts = 0
            let maxRecoveryAttempts = 3
            while !Task.isCancelled, let self {
                let delay = backoff < 2 ? 1_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: UInt64(delay))

                guard !Task.isCancelled,
                      self.state == .waitingForUsableInput,
                      self.recordingIntent == .userWantsRecording,
                      self.currentMeetingId != nil else { break }

                // Don't race with an in-progress physical restart
                guard !self.isPhysicalRestartInProgress else {
                    AppLog.audio.info("Waiting probe: restart in progress — skipping cycle")
                    continue
                }

                // Cap recovery attempts — after N failures, further attempts
                // just create empty segment files.
                guard recoveryAttempts < maxRecoveryAttempts else {
                    AppLog.audio.info("Waiting probe: max recovery attempts (\(maxRecoveryAttempts)) reached — stopping probe")
                    break
                }

                // Re-read session state — things may have changed.
                let hasBuiltInMic = self.sessionManager.session.availableInputs?.contains { $0.portType == .builtInMic } ?? false

                AppLog.audio.info("Waiting probe: builtInMic=\(hasBuiltInMic) backoff=\(backoff) attempt=\(recoveryAttempts+1)/\(maxRecoveryAttempts)")

                if hasBuiltInMic {
                    await self.forceBuiltInMicRecovery()
                    recoveryAttempts += 1
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
        // Adaptive compression: reduce sample rate when disk space is low.
        let baseRate = sessionManager.sampleRate > 0 ? sessionManager.sampleRate : 44100
        let (sessionRate, qualityTier) = adaptiveSampleRate(baseRate: baseRate)
        guard let recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate, channels: 1, interleaved: false) else {
            throw AudioCaptureError.engineStartFailed
        }
        let freeMB = freeDiskMB()
        AppLog.audio.info("Recording format: \(Int(sessionRate))Hz \(qualityTier) (free space: \(freeMB)MB)")
        currentMeetingId = meetingId
        try fileWriter.startRecording(format: recordFormat, meetingId: meetingId)

        safelyInstallTap(reason: "startRecording")
        engine.prepare()

        // Pre-arm the capture flag BEFORE engine.start(). Once the engine is
        // running, audio buffers arrive on the real-time thread immediately.
        // If _isCapturingAudio is false when the first buffer hits the tap,
        // that audio is discarded. Rolled back on start failure.
        _isCapturingAudio = true

        // Retry engine start for Bluetooth devices that need time to stabilize
        let engineStarted = await startEngineWithRetry(label: "startRecording", reinstallTap: true)

        if !engineStarted {
            _isCapturingAudio = false  // rollback pre-arm — engine never started
            safelyRemoveTap(reason: "engineStartFailed")
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
            stopTimer()
            // After 5 minutes of pause, stop the engine to save battery.
            // On resume, the engine will be rebuilt transparently.
            schedulePauseEngineTimeout()
            AppLog.audio.info("Recording paused (engine kept alive, timeout in \(Self.pauseEngineTimeoutSeconds)s)")

        case .reconfiguringRoute, .validatingRoute:
            // User paused during route switch — invalidate recovery, stay paused.
            invalidateRouteRecovery()
            transition(to: .pausedByUser, reason: "user paused during route switch")
            recordingIntent = .userPaused
            AppLog.audio.info("Recording paused — route switch cancelled")

        case .waitingForUsableInput:
            // User paused while waiting for mic.
            stopWaitingInputProbe()
            transition(to: .pausedByUser, reason: "user paused while waiting for mic")
            recordingIntent = .userPaused
            invalidateRouteRecovery()
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
        // Cancel any pending engine timeout — user is back.
        pauseEngineTimeoutTask?.cancel()
        pauseEngineTimeoutTask = nil
        if engineStoppedForPauseTimeout {
            // Engine was stopped to save battery during a long pause.
            // Rebuild it via the standard route recovery path.
            engineStoppedForPauseTimeout = false
            AppLog.audio.info("Resume after pause timeout — rebuilding engine")
            let gen = routeRecoveryGeneration
            Task { @MainActor in
                _ = await self.restartCaptureForNewRoute(reason: "resumeAfterPauseTimeout", resumeRecording: true, generation: gen)
            }
            return
        }
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
        logCrashDiagnostics("forceFinish-begin")

        // 1. Kill all async recovery tasks immediately — Stop has absolute priority
        isPhysicalRestartInProgress = false
        physicalRestartTask?.cancel()
        physicalRestartTask = nil
        routeChangeTask?.cancel()
        routeChangeTask = nil
        stopWaitingInputProbe()
        invalidateRouteRecovery()

        // 2. Mark intent as stopped — no recovery can resurrect
        recordingIntent = .userStopped

        // 3. Remove all observers
        removeAudioNotificationObservers()

        // 4. Stop timer + pause timeout
        stopTimer()
        pauseEngineTimeoutTask?.cancel()
        pauseEngineTimeoutTask = nil
        AudioFileWriter.clearCrashCheckpoint()
        levelMonitorTask?.cancel()

        // 5. Try to stop engine/tap safely — don't crash if already broken
        safelyRemoveTap(reason: "forceFinish")
        if engine.isRunning { engine.stop() }
        try? sessionManager.deactivate()

        // 6. Close any open segment
        fileWriter.finishRecording()

        // 7. Final transition
        transition(to: .stopped, reason: "forceFinish")
        audioLevel = 0.0
        elapsedTime = 0.0
        recordingStartTime = nil
        totalAutoPausedDuration = 0
        autoPauseStartDate = nil
        currentInputPortName = ""
        currentMeetingId = nil
        stateBeforeSystemInterruption = nil
        logCrashDiagnostics("forceFinish-end")
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

    /// Log detailed audio engine state for crash diagnostics.
    /// Called before and after every risky operation (removeTap, installTap,
    /// engine stop/start, session configure/deactivate).
    private func logCrashDiagnostics(_ marker: String) {
        let route = self.sessionManager.session.currentRoute
        let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }
        let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }
        let available = self.sessionManager.session.availableInputs?.map { "\($0.portName)(\($0.portType.rawValue))" } ?? []
        let intentStr: String = switch self.recordingIntent {
        case .none: "none"
        case .userWantsRecording: "wantsRecord"
        case .userPaused: "paused"
        case .userStopped: "stopped"
        }
        let msg = "CrashDiag [\(marker)]: state=\(String(describing: self.state)) intent=\(intentStr) gen=\(self.routeRecoveryGeneration.uuidString.prefix(8)) tap=\(self.isTapInstalled) engRunning=\(self.engine.isRunning) restarting=\(self.isPhysicalRestartInProgress) inputs=[\(inputs.joined(separator: ", "))] outputs=[\(outputs.joined(separator: ", "))] avail=[\(available.joined(separator: ", "))] rate=\(self.sessionManager.sampleRate) mid=\(self.currentMeetingId?.uuidString.prefix(8) ?? "nil") file=\(self.fileWriter.currentFileURL?.lastPathComponent ?? "nil")"
        AppLog.audio.info("\(msg)")
    }

    /// Remove the audio tap only if one is installed. Calling removeTap when
    /// no tap exists crashes on some iOS versions (AVAudioNode internal assert).
    /// Shared engine.start() retry loop. Attempts up to 3 times with 300ms
    /// sleep between attempts. Between retries, calls engine.reset() (which
    /// clears the audio graph including any installed tap) and engine.prepare().
    /// When `reinstallTap` is true, also marks isTapInstalled=false and
    /// reinstalls the tap before retrying — this is required when a tap was
    /// installed before calling this method. Logs each failure with the given
    /// label for diagnostics.
    ///
    /// - Returns: true if engine.start() succeeded, false after 3 failures.
    private func startEngineWithRetry(label: String, reinstallTap: Bool) async -> Bool {
        for attempt in 0...2 {
            do {
                try engine.start()
                return true
            } catch {
                AppLog.error("audio", "\(label): engine start attempt \(attempt+1)/3 failed: \(error.localizedDescription)")
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    engine.reset()
                    if reinstallTap {
                        isTapInstalled = false
                        engine.prepare()
                        safelyInstallTap(reason: "\(label) retry \(attempt+1)")
                    } else {
                        engine.prepare()
                    }
                }
            }
        }
        return false
    }

    private func safelyRemoveTap(reason: String) {
        guard isTapInstalled else {
            AppLog.audio.info("safelyRemoveTap: skipped — no tap installed (\(reason))")
            return
        }
        // Mark false BEFORE the ObjC call. If iOS internally cleared the tap
        // (e.g., AVAudioEngineConfigurationChange), removeTap(onBus:) on a
        // bus with no tap raises NSException — uncatchable in Swift.
        // Setting false first guarantees we never double-remove. If the call
        // succeeds, the flag was already correct. If it crashes, at least we
        // didn't corrupt state before the crash.
        isTapInstalled = false
        logCrashDiagnostics("before-removeTap[\(reason)]")
        engine.inputNode.removeTap(onBus: 0)
        logCrashDiagnostics("after-removeTap[\(reason)]")
    }

    /// Install the audio tap, removing any existing tap first.
    /// Safe to call even if a tap is already installed.
    private func safelyInstallTap(reason: String) {
        if isTapInstalled {
            AppLog.audio.info("safelyInstallTap: removing existing tap first (\(reason))")
            engine.inputNode.removeTap(onBus: 0)
        }
        logCrashDiagnostics("before-installTap[\(reason)]")
        installTap()
        isTapInstalled = true
        logCrashDiagnostics("after-installTap[\(reason)]")
    }

    /// Install the audio tap. Copies raw PCM samples and dispatches to the
    /// AudioFileWriter's internal serial queue. The writer is the single
    /// serialization point for all audio data — no external write queue needed.
    private func installTap() {
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateAudioLevel(from: buffer)
            self.lastBufferReceivedAt = Date()  // Track for route validation
            guard self._isCapturingAudio else { return }

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
        // Guard against concurrent restarts — corrupting the engine kills the app.
        guard !isPhysicalRestartInProgress else {
            AppLog.audio.info("restartCapture: physical restart already in progress — skipping")
            return .noUsableInput(takeRouteSnapshot(reason: "skipped: restart in progress"))
        }
        isPhysicalRestartInProgress = true
        armRestartWatchdog()
        defer {
            cancelRestartWatchdog()
            isPhysicalRestartInProgress = false
            drainPendingRouteChanges()
        }

        logCrashDiagnostics("restartCapture-begin[\(reason)]")
        transition(to: .reconfiguringRoute, reason: "restart capture: \(reason)")
        timerTask?.cancel()

        // 1. Checkpoint the current segment BEFORE touching anything else.
        _ = checkpointCurrentSegment(reason: reason)

        // 2. Clean stop: remove tap, stop engine, release engine.
        safelyRemoveTap(reason: "restartCapture teardown: \(reason)")
        logCrashDiagnostics("restartCapture-before-stop[\(reason)]")
        engine.stop()
        logCrashDiagnostics("restartCapture-after-stop[\(reason)]")

        guard let meetingId = currentMeetingId else {
            audioInterruptionReason = "Internal error."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        // 3. Return audio resources to the system BEFORE creating anything new.
        //    Deactivate the session, let the system settle, then reconfigure
        //    from a completely clean state — exactly like startRecording.
        //    Bluetooth routes need longer settle time (750ms vs 500ms).
        try? sessionManager.deactivate()
        let settleNs = sessionManager.settleDelayNs
        AppLog.audio.info("restartCapture: settle delay \(settleNs / 1_000_000)ms")
        try? await Task.sleep(nanoseconds: settleNs)

        // 4. Now create a fresh engine on a clean session.
        engine = AVAudioEngine()
        reRegisterEngineObserver()  // pin observer to the new engine instance
        logCrashDiagnostics("restartCapture-newEngine[\(reason)]")

        do {
            try sessionManager.configureForRecording()
        } catch {
            AppLog.error("audio", "restartCapture: session configure failed: \(error)")
            audioInterruptionReason = "Could not configure audio."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        guard sessionManager.isInputAvailable else {
            // Try builtInMic before giving up — the iPhone mic is the reliable fallback.
            if sessionManager.session.availableInputs?.contains(where: { $0.portType == .builtInMic }) ?? false {
                AppLog.audio.info("restartCapture: no input but builtInMic available — forcing fallback")
                await forceBuiltInMicRecovery()
                return .resumed(takeRouteSnapshot(reason: reason))
            }
            audioInterruptionReason = "No microphone available."
            transition(to: .waitingForUsableInput, reason: "no input after restart")
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        // 5. Open new segment with format matching the new route.
        //    Manifest is the source of truth for the segment index, NOT the
        //    AudioFileWriter's internal counter (which can drift across teardowns).
        let sessionRate = sessionManager.sampleRate
        guard let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false) else {
            AppLog.error("audio", "restartCapture: invalid audio format — rate=\(sessionRate)")
            audioInterruptionReason = "Could not create audio format."
            transition(to: .waitingForUsableInput, reason: "invalid audio format")
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        guard guardDiskSpaceForNewSegment(reason: reason) else { return .noUsableInput(takeRouteSnapshot(reason: reason)) }

        let nextIndex = nextSegmentIndexProvider?() ?? (fileWriter.segmentIndex + 1)
        do {
            // The old segment was already closed by checkpointCurrentSegment.
            // Use startNextSegmentForExistingRecording — it never resets the index.
            try fileWriter.startNextSegmentForExistingRecording(
                meetingId: meetingId, format: hwFmt, manifestNextIndex: nextIndex)
        } catch {
            AppLog.error("audio", "restartCapture: startNextSegment failed: \(error)")
            audioInterruptionReason = "Could not create audio segment."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)

        // 6. Install tap, prepare, pre-arm, start — identical to startRecording.
        safelyInstallTap(reason: "restartCapture new engine: \(reason)")
        engine.prepare()

        // Pre-arm so the tap writes audio immediately. During the validation
        // window below, _isCapturingAudio must be true — otherwise up to 4s
        // of Bluetooth audio is discarded. transition(to: .validatingRoute)
        // will also set it true, but there's a gap between engine.start() and
        // that transition. Rolled back on start failure.
        _isCapturingAudio = true

        let engineStartSucceeded = await startEngineWithRetry(label: "restartCapture", reinstallTap: true)

        guard generation == routeRecoveryGeneration else {
            fileWriter.closeCurrentSegment()
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        if !engineStartSucceeded {
            _isCapturingAudio = false  // rollback pre-arm — engine never started
            _ = checkpointCurrentSegment(reason: "engineStartFailed")
            try? sessionManager.deactivate()
            // Don't just give up — try builtInMic before waiting. The iPhone mic
            // is always available and is the reliable fallback when Bluetooth fails.
            if sessionManager.session.availableInputs?.contains(where: { $0.portType == .builtInMic }) ?? false {
                AppLog.audio.info("restartCapture: engine start failed — falling back to built-in mic")
                await forceBuiltInMicRecovery()
                return .resumed(takeRouteSnapshot(reason: reason))
            }
            audioInterruptionReason = "Could not start audio with this microphone."
            transition(to: .waitingForUsableInput, reason: "engine start failed")
            return .engineFailed(NSError(domain: "Audio", code: -1), takeRouteSnapshot(reason: reason))
        }

        // 7. Validation — wait for first buffer with adaptive timeout.
        //    Bluetooth HFP can take 2-4s to deliver PCM after engine start.
        transition(to: .validatingRoute, reason: "validating: \(reason)")
        let timeoutMs = Int(sessionManager.validationTimeoutSeconds * 1000)
        let maxIterations = timeoutMs / 100  // 100ms per iteration
        AppLog.audio.info("restartCapture: validation timeout=\(timeoutMs)ms iterations=\(maxIterations)")
        let bufferCheckStart = lastBufferReceivedAt
        for _ in 0..<maxIterations where lastBufferReceivedAt <= bufferCheckStart {
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
            onSegmentCreated?(nil, segment)
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

        // No buffers — route is silent. Try builtInMic before giving up.
        // Previous segment already checkpointed via checkpointCurrentSegment at top;
        // just close the empty current segment and try builtInMic.
        _ = checkpointCurrentSegment(reason: "validationFailed")
        try? sessionManager.deactivate()
        if sessionManager.session.availableInputs?.contains(where: { $0.portType == .builtInMic }) ?? false {
            AppLog.audio.info("restartCapture: validation failed but builtInMic available — forcing fallback")
            await forceBuiltInMicRecovery()
            return .resumed(takeRouteSnapshot(reason: reason))
        }
        audioInterruptionReason = "Microphone not delivering audio. Waiting…"
        transition(to: .waitingForUsableInput, reason: "validation failed")
        return .noUsableInput(takeRouteSnapshot(reason: reason))
    }

    // Simple engine rebuild without segment creation (used for startRecording only).
    private func rebuildEngine() {
        safelyRemoveTap(reason: "rebuildEngine")
        engine.stop()
        engine.reset()
        safelyInstallTap(reason: "rebuildEngine")
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

        // Guard against concurrent restarts
        guard !isPhysicalRestartInProgress else {
            AppLog.audio.info("forceBuiltInMic: restart already in progress — skipping")
            return
        }
        isPhysicalRestartInProgress = true
        armRestartWatchdog()
        defer {
            cancelRestartWatchdog()
            isPhysicalRestartInProgress = false
            drainPendingRouteChanges()
        }

        logCrashDiagnostics("forceBuiltInMic-begin")
        AppLog.audio.info("Force built-in mic recovery — beginning")

        // Cancel any in-progress recovery
        invalidateRouteRecovery()
        let gen = routeRecoveryGeneration

        // Clean stop — release everything before creating new
        safelyRemoveTap(reason: "forceBuiltInMic teardown")
        logCrashDiagnostics("forceBuiltInMic-before-stop")
        engine.stop()
        logCrashDiagnostics("forceBuiltInMic-after-stop")
        try? sessionManager.deactivate()
        let settleNs = sessionManager.settleDelayNs
        try? await Task.sleep(nanoseconds: settleNs) // adaptive: 500ms built-in, 750ms Bluetooth

        // Fresh engine on clean session
        engine = AVAudioEngine()
        reRegisterEngineObserver()  // pin observer to the new engine instance
        logCrashDiagnostics("forceBuiltInMic-newEngine")
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

        // Open new segment — manifest is source of truth for the index
        let sessionRate = sessionManager.sampleRate
        guard let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false) else {
            AppLog.error("audio", "forceBuiltInMic: invalid audio format — rate=\(sessionRate)")
        guard guardDiskSpaceForNewSegment(reason: "forceBuiltInMic") else { return }

            audioInterruptionReason = "Could not create audio format."
            transition(to: .waitingForUsableInput, reason: "invalid audio format")
            return
        }
        let nextIndex = nextSegmentIndexProvider?() ?? (fileWriter.segmentIndex + 1)
        try? fileWriter.startNextSegmentForExistingRecording(
            meetingId: meetingId, format: hwFmt, manifestNextIndex: nextIndex)
        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)

        // Start engine — pre-arm so audio during validation is captured
        safelyInstallTap(reason: "forceBuiltInMic new engine")
        engine.prepare()
        _isCapturingAudio = true
        let started = await startEngineWithRetry(label: "forceBuiltInMic", reinstallTap: false)

        guard started else {
            _isCapturingAudio = false  // rollback pre-arm
            fileWriter.closeCurrentSegment()
            audioInterruptionReason = "Could not start iPhone microphone."
            transition(to: .waitingForUsableInput, reason: "built-in mic engine failed")
            return
        }

        // Validate — use same adaptive timeout as restartCaptureForNewRoute
        transition(to: .validatingRoute, reason: "validating built-in mic")
        let timeoutMs = Int(sessionManager.validationTimeoutSeconds * 1000)
        let maxIterations = timeoutMs / 100
        let bufStart = lastBufferReceivedAt
        for _ in 0..<maxIterations where lastBufferReceivedAt <= bufStart {
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
        onSegmentCreated?(nil, segment)
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
    private var engineConfigChangeObserver: NSObjectProtocol?
    private var silenceHintObserver: NSObjectProtocol?

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
        // Siri / VoiceOver may not trigger interruptionNotification — instead the
        // system sends silenceSecondaryAudioHint to tell us our audio should be
        // silenced. Observing this prevents recording silent buffers when Siri
        // takes the microphone without a full interruption.
        silenceHintObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleSilenceHint(notification)
        }

        // CRITICAL: AVAudioEngineConfigurationChange fires BEFORE routeChangeNotification
        // when Bluetooth connects. iOS internally clears all taps and stops the engine.
        // Without this observer, isTapInstalled stays true → removeTap(onBus:) crashes.
        // Scoped to this engine instance — must be re-registered when engine is replaced.
        reRegisterEngineObserver()
    }

    private func removeAudioNotificationObservers() {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = mediaServicesResetObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = engineConfigChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = silenceHintObserver { NotificationCenter.default.removeObserver(obs) }
        interruptionObserver = nil
        routeChangeObserver = nil
        mediaServicesResetObserver = nil
        engineConfigChangeObserver = nil
        silenceHintObserver = nil
    }

    /// Handles AVAudioSession.silenceSecondaryAudioHintNotification.
    /// Siri, VoiceOver, and other system audio services may take the microphone
    /// without firing a full interruptionNotification. When the hint type is
    /// `.begin`, we pause audio writing so we don't record silence. When `.end`,
    /// we resume writing if the recording is still active.
    private func handleSilenceHint(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else { return }

        switch type {
        case .begin:
            AppLog.audio.info("Silence hint began — pausing audio writing (likely Siri/VoiceOver)")
            _isCapturingAudio = false
        case .end:
            if state == .recording || state == .validatingRoute {
                AppLog.audio.info("Silence hint ended — resuming audio writing")
                _isCapturingAudio = true
            }
        @unknown default:
            break
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            AppLog.event("audio", "System interruption began — state=\(state)")
            stateBeforeSystemInterruption = state
            // Cancel any in-progress route rebuild. If a phone call arrives
            // while we're validating a Bluetooth route, the rebuild would
            // otherwise complete after the call takes the audio path and
            // incorrectly transition back to .recording.
            invalidateRouteRecovery(caller: "interruptionBegan")
            physicalRestartTask?.cancel()
            physicalRestartTask = nil
            if state == .recording || state == .validatingRoute || state == .reconfiguringRoute {
                transition(to: .interruptedBySystem, reason: "system interruption began")
                audioInterruptionReason = "Recording paused due to interruption (phone call, alarm, etc.)."
                stopTimer()
                _ = checkpointCurrentSegment(reason: "systemInterruptionBegan")
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            let shouldResume = options?.contains(.shouldResume) == true

            if shouldResume {
                AppLog.audio.info("System interruption ended — validating session before rebuild")
                // After a phone call ends, the shared AVAudioSession may have
                // been reconfigured by the phone app (category changed, mode
                // switched). Validate and repair before rebuilding the engine.
                let session = AVAudioSession.sharedInstance()
                if session.category != .playAndRecord {
                    AppLog.audio.info("Session category is \(session.category.rawValue) after interruption — reconfiguring to .playAndRecord")
                    do {
                        try sessionManager.configureForRecording()
                    } catch {
                        AppLog.error("audio", "Failed to reconfigure session after interruption: \(error)")
                    }
                }
                // Always rebuild the engine when the system says we can resume.
                // The previous code only rebuilt if recordingIntent == .userWantsRecording,
                // but if the user pressed Pause *during* the interruption, the intent is
                // .userPaused and the engine was never rebuilt — leaving it dead on Resume.
                let wantsRecording = recordingIntent == .userWantsRecording
                let gen = routeRecoveryGeneration
                physicalRestartTask = Task { @MainActor in
                    _ = await self.restartCaptureForNewRoute(reason: "interruptionEnded", resumeRecording: wantsRecording, generation: gen)
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

        // Debounce timing varies by reason. Bluetooth HFP negotiation can
        // fire 3-4 notifications in rapid succession and needs ~500ms to
        // settle. Device removal is final — no more notifications coming,
        // so process immediately. Category changes and overrides settle
        // faster than new-device discovery.
        let debounceNs: UInt64 = switch reason {
        case .oldDeviceUnavailable: 0           // device is gone — act now
        case .newDeviceAvailable:   500_000_000  // Bluetooth negotiation window
        case .categoryChange,
             .override,
             .wakeFromSleep:        250_000_000  // faster settling
        default:                    500_000_000  // safe default for unknown reasons
        }

        routeChangeTask?.cancel()
        if debounceNs == 0 {
            routeChangeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.processSettledRouteChange(reason)
            }
        } else {
            routeChangeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: debounceNs)
                guard let self, !Task.isCancelled else { return }
                await self.processSettledRouteChange(reason)
            }
        }
    }

    /// Schedules a task that stops the engine after a long pause to conserve
    /// battery. The engine consumes ~3-5% battery per hour when idling.
    /// On resume, the engine is rebuilt transparently via route recovery.
    private func schedulePauseEngineTimeout() {
        pauseEngineTimeoutTask?.cancel()
        pauseEngineTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pauseEngineTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled,
                  self.state == .pausedByUser,
                  self.recordingIntent == .userPaused else { return }
            AppLog.audio.info("Pause timeout (\(Self.pauseEngineTimeoutSeconds)s) — stopping engine to save battery")
            self.engineStoppedForPauseTimeout = true
            self.safelyRemoveTap(reason: "pauseEngineTimeout")
            self.engine.stop()
            self.isTapInstalled = false
        }
    }

    /// Checks whether there's enough free disk space for a new audio segment.
    /// If below the critical threshold, transitions to .failedFatal and returns
    /// false so the caller can abort the route change without losing existing
    /// segments (which are already safely checkpointed).
    private func guardDiskSpaceForNewSegment(reason: String) -> Bool {
        let store = FileArtifactStore()
        guard let free = store.freeSpaceForCurrentRecording(), free > 5_000_000 else {
            AppLog.error("audio", "CRITICAL: insufficient disk space for new segment (\(reason)) — stopping recording to preserve existing audio")
            audioInterruptionReason = "Recording stopped — storage is full."
            transition(to: .failedFatal("diskFull"), reason: "pre-segment disk check: \(reason)")
            return false
        }
        return true
    }

    /// Drains the pending route change queue after a physical restart completes.
    /// Multiple route changes can stack up during Bluetooth negotiation (e.g.
    /// AirPods connecting → disconnecting → connecting again in <2s). Each is
    /// processed sequentially so the last one wins, rather than silently losing
    /// intermediate transitions.
    private func drainPendingRouteChanges() {
        let pending = pendingRouteChanges
        guard !pending.isEmpty else { return }
        pendingRouteChanges.removeAll()
        AppLog.audio.info("Draining \(pending.count) deferred route change(s)")
        for reason in pending {
            Task { @MainActor [weak self] in
                await self?.processSettledRouteChange(reason)
            }
        }
    }

    @MainActor
    private func processSettledRouteChange(_ reason: AVAudioSession.RouteChangeReason) async {
        // Don't stack route changes on top of an in-progress restart.
        // Instead of silently dropping the change, store it so the running
        // restart can drain it when it completes (prevents lost route changes).
        guard !isPhysicalRestartInProgress else {
            AppLog.audio.info("Route settled: restart already in progress — deferring route change (reason=\(reason.rawValue)) queueDepth=\(self.pendingRouteChanges.count + 1)")
            pendingRouteChanges.append(reason)
            return
        }

        let portName = sessionManager.currentInputPortName
        let inputAvailable = sessionManager.isInputAvailable
        AppLog.audio.info("Route settled: reason=\(reason.rawValue) port=\(portName) inputAvailable=\(inputAvailable)")

        // Input lost while recording or user-paused — try builtInMic first
        guard inputAvailable else {
            if recordingIntent == .userWantsRecording || recordingIntent == .userPaused {
                AppLog.audio.info("Input lost — checking builtInMic availability")
                if sessionManager.session.availableInputs?.contains(where: { $0.portType == .builtInMic }) ?? false {
                    AppLog.audio.info("Input lost but builtInMic available — forcing fallback")
                    await forceBuiltInMicRecovery()
                    currentInputPortName = sessionManager.currentInputPortName
                    return
                }
                transition(to: .waitingForUsableInput, reason: "input lost")
                audioInterruptionReason = "Microphone disconnected. Waiting for input…"
                stopTimer()
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
        // CRITICAL: media services reset destroys the entire audio stack
        // including all engine taps. Mark tap as NOT installed before
        // triggering rebuild, otherwise safelyInstallTap will try to
        // removeTap(onBus:) on the new engine (which has no tap) and crash.
        isTapInstalled = false
        if recordingIntent == .userWantsRecording || recordingIntent == .userPaused {
            let resume = recordingIntent == .userWantsRecording
            let gen = routeRecoveryGeneration
            physicalRestartTask = Task { @MainActor in
                _ = await self.restartCaptureForNewRoute(reason: "mediaServicesReset", resumeRecording: resume, generation: gen)
            }
        }
    }

    // MARK: - Engine configuration change (Bug 1 fix)

    /// Handles AVAudioEngineConfigurationChange — the primary crash cause when
    /// Bluetooth connects mid-recording.
    ///
    /// iOS fires this notification BEFORE routeChangeNotification and immediately
    /// clears the engine's audio graph (including all taps). The engine is left
    /// in an invalidated state. We must:
    /// 1. Mark the tap as NOT installed (iOS already cleared it).
    /// 2. Cancel any pending route-change debounce (configuration change supersedes it).
    /// 3. If the user still wants to record, rebuild the engine WITHOUT touching
    ///    the audio session — iOS has already routed audio to the new device.
    ///    Deactivating/reactivating the session would tear down the Bluetooth
    ///    SCO link and cause engine.start() to fail.
    private func handleEngineConfigurationChange() {
        AppLog.audio.info("Engine configuration change — audio graph has been reset")

        // CRITICAL: iOS has already cleared the tap. Mark it false immediately
        // to prevent any subsequent safelyRemoveTap from crashing on a stale tap.
        isTapInstalled = false

        // Cancel the route-change debounce — the configuration change provides
        // a fresher signal about what just happened to the audio hardware.
        routeChangeTask?.cancel()
        routeChangeTask = nil

        // If the user wants recording, rebuild now. Don't wait for the
        // routeChangeNotification debounce — the engine is already dead.
        guard recordingIntent == .userWantsRecording || recordingIntent == .userPaused else {
            AppLog.audio.info("Engine config change: no recording intent — skipping rebuild")
            return
        }

        guard !isPhysicalRestartInProgress else {
            AppLog.audio.info("Engine config change: restart already in progress — deferring")
            return
        }

        let resume = recordingIntent == .userWantsRecording
        invalidateRouteRecovery()
        let gen = routeRecoveryGeneration
        AppLog.audio.info("Engine config change: triggering lightweight rebuild (resume=\(resume))")
        physicalRestartTask = Task { @MainActor [weak self] in
            _ = await self?.rebuildForNewAudioRoute(
                reason: "engineConfigChange", resumeRecording: resume, generation: gen)
        }
    }

    /// Lightweight engine rebuild for route-driven configuration changes
    /// (Bluetooth connect/disconnect). iOS has already switched the audio
    /// session to the new device — we must NOT deactivate or reconfigure
    /// the session, as that would tear down the Bluetooth SCO link and
    /// cause engine.start() to fail.
    ///
    /// Only replaces the engine and reinstalls the tap. The audio session
    /// remains active with the new route throughout.
    @discardableResult
    private func rebuildForNewAudioRoute(reason: String, resumeRecording: Bool, generation: UUID) async -> AudioRebuildResult {
        guard !isPhysicalRestartInProgress else {
            AppLog.audio.info("rebuildForNewRoute: physical restart already in progress — skipping")
            return .noUsableInput(takeRouteSnapshot(reason: "skipped: restart in progress"))
        }
        isPhysicalRestartInProgress = true
        armRestartWatchdog()
        defer {
            cancelRestartWatchdog()
            isPhysicalRestartInProgress = false
            drainPendingRouteChanges()
        }

        logCrashDiagnostics("rebuildForNewRoute-begin[\(reason)]")
        transition(to: .reconfiguringRoute, reason: "rebuild for new route: \(reason)")
        timerTask?.cancel()

        // 1. Checkpoint current segment — preserve pre-switch audio.
        _ = checkpointCurrentSegment(reason: reason)

        // 2. Stop old engine. Tap was already cleared by iOS
        //    (isTapInstalled was set false in handleEngineConfigurationChange).
        engine.stop()
        logCrashDiagnostics("rebuildForNewRoute-after-stop[\(reason)]")

        guard let meetingId = currentMeetingId else {
            audioInterruptionReason = "Internal error."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        // 3. Fresh engine on the ALREADY-ACTIVE session. Do NOT deactivate
        //    or reconfigure — iOS has already routed to the new device.
        //    However, the new device may need a different audio mode than the
        //    previous one (e.g. AirPods HFP → .default, built-in mic →
        //    .spokenAudio). adaptToRouteChange() only updates the mode without
        //    deactivating the session, so it's safe here.
        engine = AVAudioEngine()
        reRegisterEngineObserver()
        sessionManager.adaptToRouteChange()
        logCrashDiagnostics("rebuildForNewRoute-newEngine[\(reason)]")

        // 4. Read current route format directly from the active session.
        let sessionRate = sessionManager.sampleRate
        guard let hwFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sessionRate > 0 ? sessionRate : 44100, channels: 1, interleaved: false) else {
            AppLog.error("audio", "rebuildForNewRoute: invalid audio format — rate=\(sessionRate)")
            audioInterruptionReason = "Could not create audio format."
            transition(to: .waitingForUsableInput, reason: "invalid audio format")
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        guard guardDiskSpaceForNewSegment(reason: reason) else { return .noUsableInput(takeRouteSnapshot(reason: reason)) }

        // 5. Open new segment with format matching the new route.
        let nextIndex = nextSegmentIndexProvider?() ?? (fileWriter.segmentIndex + 1)
        do {
            try fileWriter.startNextSegmentForExistingRecording(
                meetingId: meetingId, format: hwFmt, manifestNextIndex: nextIndex)
        } catch {
            AppLog.error("audio", "rebuildForNewRoute: startNextSegment failed: \(error)")
            audioInterruptionReason = "Could not create audio segment."
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        let segIndex = fileWriter.segmentIndex
        let segFileName = fileWriter.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)
        let inputPortName = sessionManager.currentInputPortName
        let inputPortType = sessionManager.bestAvailableInput?.portType.rawValue ?? "unknown"
        AppLog.audio.info("rebuildForNewRoute: new segment \(segIndex) \(segFileName) rate=\(sessionRate)Hz input=\(inputPortName)(\(inputPortType))")

        // 6. Install tap, pre-arm, start engine.
        safelyInstallTap(reason: "rebuildForNewRoute: \(reason)")
        engine.prepare()
        _isCapturingAudio = true

        let engineStartSucceeded = await startEngineWithRetry(label: "rebuildForNewRoute", reinstallTap: true)

        guard generation == routeRecoveryGeneration else {
            fileWriter.closeCurrentSegment()
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        if !engineStartSucceeded {
            _isCapturingAudio = false
            _ = checkpointCurrentSegment(reason: "engineStartFailed")
            // Release the mutex so forceBuiltInMicRecovery can acquire it.
            isPhysicalRestartInProgress = false
            await forceBuiltInMicRecovery()
            return .resumed(takeRouteSnapshot(reason: reason))
        }

        // 7. Validation — wait for first buffer.
        transition(to: .validatingRoute, reason: "validating new route: \(reason)")
        let timeoutMs = Int(sessionManager.validationTimeoutSeconds * 1000)
        let maxIterations = timeoutMs / 100
        let bufferCheckStart = lastBufferReceivedAt
        for _ in 0..<maxIterations where lastBufferReceivedAt <= bufferCheckStart {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard generation == routeRecoveryGeneration else {
            fileWriter.closeCurrentSegment()
            return .noUsableInput(takeRouteSnapshot(reason: reason))
        }

        if lastBufferReceivedAt > bufferCheckStart {
            let segment = RecordingSegment(
                id: UUID(), index: segIndex, fileName: segFileName, startedAt: Date(),
                inputPortName: inputPortName, inputPortType: inputPortType,
                routeChangeReason: reason, sampleRate: hwFmt.sampleRate
            )
            onSegmentCreated?(nil, segment)
            currentInputPortName = inputPortName
            audioInterruptionReason = nil
            let snap = takeRouteSnapshot(reason: reason)

            if resumeRecording, recordingIntent == .userWantsRecording {
                _ = commitRecoveredRouteToRecording(generation: generation, reason: "route rebuild: \(reason)")
                return .resumed(snap)
            } else {
                transition(to: .pausedByUser, reason: "route rebuild (paused)")
                return .paused(snap)
            }
        }

        // No buffers — lightweight rebuild didn't produce audio.
        // Release the mutex and fall back to a full session reset.
        _ = checkpointCurrentSegment(reason: "validationFailed")
        isPhysicalRestartInProgress = false
        await forceBuiltInMicRecovery()
        return .resumed(takeRouteSnapshot(reason: reason))
    }

    /// Re-register the engine-scoped configuration-change observer.
    /// MUST be called every time `engine = AVAudioEngine()` is executed,
    /// because the observer is pinned to a specific engine instance via
    /// `object: engine`. The old observer stops firing for the new engine.
    private func reRegisterEngineObserver() {
        if let obs = engineConfigChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        engineConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,        // scoped to THIS engine instance
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        checkpointTask?.cancel()
        diskSpaceCheckTask?.cancel()
        recordingStartTime = Date()
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let start = self.recordingStartTime {
                    var elapsed = Date().timeIntervalSince(start)
                    // Subtract accumulated auto-pause duration so the timer
                    // freezes during silence (same behavior as manual pause).
                    if let autoStart = self.autoPauseStartDate {
                        elapsed -= (self.totalAutoPausedDuration + Date().timeIntervalSince(autoStart))
                    } else {
                        elapsed -= self.totalAutoPausedDuration
                    }
                    await MainActor.run {
                        self.elapsedTime = max(0, elapsed)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.timerUpdateInterval * 1_000_000_000))
            }
        }
        // Crash recovery checkpoint every 5s
        checkpointTask = Task { [weak self] in
            guard let self else { return }
            var lastCheckpoint = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.checkpointInterval * 1_000_000_000))
                guard !Task.isCancelled, let mid = self.currentMeetingId else { return }
                let rate = self.sessionManager.sampleRate > 0 ? self.sessionManager.sampleRate : 44100
                guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
                self.fileWriter.writeCheckpoint(meetingId: mid, segmentIndex: self.fileWriter.segmentIndex, format: fmt)
                lastCheckpoint = Date()
            }
        }
        // Periodic disk space check — prevents silent audio loss when disk
        // fills mid-recording (iCloud backup, app downloads, etc.).
        diskSpaceCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.diskSpaceCheckInterval * 1_000_000_000))
                guard !Task.isCancelled, self.state == .recording || self.state == .validatingRoute else { continue }
                guard let mid = self.currentMeetingId else { return }
                // Check free space on the volume containing the meeting directory.
                let store = FileArtifactStore()
                let free = store.freeSpaceForCurrentRecording() ?? .max
                AppLog.audio.debug("Disk check: free=\(free/1_000_000)MB meetingId=\(mid.uuidString.prefix(8))")
                if free < Self.criticalDiskThreshold {
                    AppLog.error("audio", "CRITICAL: free space \(free/1_000_000)MB — stopping recording to preserve audio")
                    _ = self.checkpointCurrentSegment(reason: "criticalDiskSpace")
                    await MainActor.run {
                        self.audioInterruptionReason = "Recording stopped — storage is full."
                        self.transition(to: .failedFatal("diskFull"), reason: "critical disk space: \(free) bytes free")
                    }
                    return
                } else if free < Self.lowDiskWarningThreshold {
                    AppLog.audio.warning("Low disk space: \(free/1_000_000)MB free — consider freeing space")
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        checkpointTask?.cancel()
        checkpointTask = nil
        diskSpaceCheckTask?.cancel()
        diskSpaceCheckTask = nil
        stopSilenceDetection()
    }

    // MARK: - Audio level

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        // vDSP_maxmgv: vectorized max-magnitude via Accelerate NEON SIMD.
        // Guaranteed zero heap allocation — safe for real-time audio thread.
        // The manual for-loop was also zero-allocation in practice (Swift
        // inlines Float.abs), but vDSP is explicitly documented as real-time
        // safe and ~4x faster via SIMD on Apple Silicon.
        var peak: Float = 0.0
        vDSP_maxmgv(channelData[0], 1, &peak, vDSP_Length(frameLength))
        audioLevelLock.withLock {
            rawAudioLevel = min(1.0, peak * 4.0)
        }
    }

    private func startLevelSmoothing() {
        levelMonitorTask?.cancel()
        silenceDetectionTask?.cancel()
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
        // Silence detection: auto-pause after sustained silence.
        // Uses hysteresis: silence threshold triggers pause at 5s,
        // audio must exceed threshold * 3 to resume (avoids noise flapping).
        silenceDetectionTask = Task { [weak self] in
            guard let self else { return }
            var silentStart: Date?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                guard self.state == .recording || self.isAutoPaused else {
                    silentStart = nil
                    continue
                }
                let level = await MainActor.run { self.audioLevel }
                if level < Self.silenceThreshold {
                    let now = Date()
                    if silentStart == nil { silentStart = now }
                    let duration = now.timeIntervalSince(silentStart ?? now)
                    await MainActor.run {
                        self.silenceDetected = duration > 1.0
                        if duration > Self.silenceDurationBeforePause && !self.isAutoPaused {
                            self.isAutoPaused = true
                            // Freeze elapsed time during silence so the reported
                            // duration reflects actual speech, not dead air.
                            self.autoPauseStartDate = Date()
                            // Stop writing silence to the file — saves disk space
                            // and prevents the transcriber from processing empty audio.
                            self._isCapturingAudio = false
                            AppLog.audio.info("Auto-paused: silence for \(Int(duration))s")
                        }
                    }
                } else if level > Self.silenceThreshold * 3 {
                    if let start = silentStart {
                        let duration = Date().timeIntervalSince(start)
                        await MainActor.run {
                            self.silenceDetected = false
                            if self.isAutoPaused {
                                self.isAutoPaused = false
                                // Accumulate auto-pause duration so elapsed time
                                // correctly excludes this silence period.
                                if let autoStart = self.autoPauseStartDate {
                                    self.totalAutoPausedDuration += Date().timeIntervalSince(autoStart)
                                    self.autoPauseStartDate = nil
                                }
                                // Resume writing — audio is back.
                                if self.state == .recording {
                                    self._isCapturingAudio = true
                                }
                                AppLog.audio.info("Auto-resumed after \(Int(duration))s silence (total auto-paused: \(Int(self.totalAutoPausedDuration))s)")
                            }
                        }
                    }
                    silentStart = nil
                }
            }
        }
    }

    private func stopSilenceDetection() {
        silenceDetectionTask?.cancel()
        silenceDetectionTask = nil
        isAutoPaused = false
        // Accumulate any in-progress auto-pause so elapsed time is correct
        if let autoStart = autoPauseStartDate {
            totalAutoPausedDuration += Date().timeIntervalSince(autoStart)
            autoPauseStartDate = nil
        }
    }

    // MARK: - Adaptive Compression

    /// Returns (sampleRate, qualityLabel) based on available disk space.
    /// Reduces quality to prevent filling the device during long recordings.
    private func adaptiveSampleRate(baseRate: Double) -> (Double, String) {
        let freeMB = freeDiskMB()
        switch freeMB {
        case ..<50:
            AppLog.audio.warning("Critical disk space (\(freeMB)MB) — using minimal quality")
            return (11025, "low")
        case 50..<200:
            AppLog.audio.info("Low disk space (\(freeMB)MB) — using reduced quality")
            return (22050, "medium")
        case 200..<500:
            return (baseRate > 44100 ? 44100 : baseRate, "high")
        default:
            return (baseRate, "full")
        }
    }

    /// Available free disk space in megabytes.
    private func freeDiskMB() -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let free = attrs[.systemFreeSize] as? Int64 {
                return free / 1_048_576
            }
        } catch {
            AppLog.audio.warning("Could not read disk free space: \(error)")
        }
        return Int64.max // If we can't read, assume plenty
    }
}
