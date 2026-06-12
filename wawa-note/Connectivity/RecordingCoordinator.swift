import SwiftData
import OSLog
import AVFoundation
import Combine

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingUIState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var isClipping: Bool = false
    @Published private(set) var clipCount: Int = 0
    @Published private(set) var liveTranscriptionText: String = ""
    @Published private(set) var isAutoPaused: Bool = false
    @Published private(set) var silenceDetected: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedItemId: UUID?
    @Published private(set) var currentInputPortName: String = ""
    @Published private(set) var currentInputIcon: String = "mic.fill"

    private let captureService: AudioCaptureService
    private let nowPlayingController: NowPlayingController
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext
    private let contextCaptureService = ContextCaptureService()
    private var annotationService: AnnotationService
    var contentPipeline: ContentPipelineService?
    /// When set, pipeline processing is enqueued through this service instead of
    /// calling ContentPipelineService.process() directly. This enables retry with
    /// backoff, offline queueing, and cancellation — direct calls skip all of that.
    var processingQueue: ProcessingQueueService?

    private var recordingStartDate: Date?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartDate: Date?
    private var recordingTitle: String = ""
    private var observationTimer: Timer?
    private var nowPlayingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Segmented recording manifest (segments managed by AudioCaptureService)
    private var manifest: RecordingManifest?

    var onStatusChange: ((RecordingStatus) -> Void)?

    var outputFileURL: URL? { captureService.outputFileURL }

    var elapsedTimeFormatted: String {
        let effective = elapsedTime - pausedDuration
        let m = Int(effective) / 60
        let s = Int(effective) % 60
        return String(format: "%02d:%02d", m, s)
    }

    init(
        modelContainer: ModelContainer,
        captureService: AudioCaptureService = AudioCaptureService(),
        nowPlayingController: NowPlayingController = NowPlayingController()
    ) {
        self.modelContainer = modelContainer
        self.captureService = captureService
        self.nowPlayingController = nowPlayingController
        let context = ModelContext(modelContainer)
        self.modelContext = context
        self.annotationService = AnnotationService(context: context)

        // Route change → new segment created by AudioCaptureService
        captureService.onSegmentCreated = { [weak self] closedInfo, newSegment in
            guard let self, var m = self.manifest else { return }
            // Finalize previous segment with accurate metadata from the writer
            if let info = closedInfo, let lastIdx = m.segments.indices.last {
                m.segments[lastIdx].endedAt = info.endedAt
                m.segments[lastIdx].fileSize = info.fileSize
            }
            m.segments.append(newSegment)
            self.manifest = m
            if let itemId = self.savedItemId {
                self.saveManifest(m, meetingId: itemId)
            }
        }

        // Interruption began → segment closed without opening a new one.
        // Finalize the CLOSED segment's metadata by its index, not blindly
        // the last segment. Recovery attempts open/close segments that were
        // never added to the manifest via onSegmentCreated — updating
        // segments[lastIdx] would overwrite an unrelated segment's data.
        captureService.onSegmentClosed = { [weak self] closedInfo in
            guard let self, var m = self.manifest else { return }
            if let idx = m.segments.firstIndex(where: { $0.index == closedInfo.index }) {
                m.segments[idx].endedAt = closedInfo.endedAt
                m.segments[idx].fileSize = closedInfo.fileSize
            } else {
                // Orphan segment from a failed recovery attempt — never
                // registered via onSegmentCreated. Add it now so its audio
                // (even if partial/silent) is tracked and transcribable.
                let orphan = RecordingSegment(
                    id: UUID(), index: closedInfo.index,
                    fileName: closedInfo.fileName,
                    startedAt: Date(),
                    inputPortName: "",
                    inputPortType: "unknown",
                    routeChangeReason: "recovery-orphan",
                    sampleRate: nil
                )
                m.segments.append(orphan)
                if let lastIdx = m.segments.indices.last {
                    m.segments[lastIdx].endedAt = closedInfo.endedAt
                    m.segments[lastIdx].fileSize = closedInfo.fileSize
                }
            }
            self.manifest = m
            if let itemId = self.savedItemId {
                self.saveManifest(m, meetingId: itemId)
            }
        }

        // Manifest is the source of truth for the next segment index — NOT
        // the AudioFileWriter's internal counter, which can get confused
        // across engine teardown/recreation cycles.
        captureService.nextSegmentIndexProvider = { [weak self] in
            guard let self, let m = self.manifest else { return 0 }
            return (m.segments.map(\.index).max() ?? -1) + 1
        }

        // Keep UI state in sync with the real capture service state.
        // The capture service owns the source of truth for recording state;
        // the coordinator mirrors it for the UI layer.
        captureService.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] captureState in
                self?.syncCaptureState(captureState)
            }
            .store(in: &cancellables)

        captureService.$audioInterruptionReason
            .receive(on: RunLoop.main)
            .sink { [weak self] reason in
                self?.errorMessage = reason
                self?.notifyStatusChange()
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording lifecycle

    func startRecording(
        title: String? = nil,
        scheduledDate: Date? = nil,
        calendarEventIdentifier: String? = nil,
        projectID: UUID? = nil
    ) {
        // Auto-recover from stale state after previous recording
        if self.state == .stopped { returnToIdle() }
        guard self.state == .idle else {
            AppLog.warn("audio", "RecordingCoordinator: startRecording called but state is \(String(describing: self.state))")
            return
        }

        AppLog.event("audio", "Recording requested — title=\(title ?? "nil") projectID=\(projectID?.uuidString.prefix(8) ?? "nil")")

        let sessionManager = AudioSessionManager()
        guard sessionManager.hasMinimumDiskSpace() else {
            AppLog.warn("audio", "Recording blocked: insufficient disk space")
            errorMessage = "Not enough storage space to record. Please free up some space."
            notifyStatusChange()
            return
        }

        // Block early if mic permission is denied — avoids creating an item
        // that would be immediately rolled back when startRecording fails.
        let micPermission = AVAudioSession.sharedInstance().recordPermission
        guard micPermission != .denied else {
            AppLog.warn("audio", "Recording blocked: microphone permission denied")
            errorMessage = "Microphone access is off. Turn it on in Settings to record audio."
            notifyStatusChange()
            return
        }

        let context = modelContext
        errorMessage = nil
        savedItemId = nil

        let recordingTitle = title ?? "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
        self.recordingTitle = recordingTitle

        let item = KnowledgeItem(type: .audio, title: recordingTitle, status: .recording)
        item.scheduledDate = scheduledDate
        item.calendarEventIdentifier = calendarEventIdentifier
        if let projectID { item.projectID = projectID; item.inboxDate = nil }
        context.insert(item)

        do {
            try context.save()
        } catch {
            AppLog.error("audio", "Failed to save knowledge item for recording: \(error.localizedDescription)")
            errorMessage = "Could not save recording. Try again."
            notifyStatusChange()
            return
        }

        let itemId = item.id
        savedItemId = itemId

        Task { @MainActor in
            do {
                try await captureService.startRecording(meetingId: itemId)
                recordingStartDate = Date()
                state = .recording
                startObservation()
                activateLockScreenControls()
                notifyStatusChange()
                captureContextSafely(for: itemId)
                // First segment — read actual file name from the writer (may be .wav for
                // low sample rates like Bluetooth HFP 8kHz). The writer is the source of truth.
        let writer = captureService.fileWriter
        let segIndex = writer.segmentIndex
        let segFileName = writer.currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", segIndex)
        let firstSegment = RecordingSegment(
            id: UUID(), index: segIndex,
            fileName: segFileName,
            startedAt: Date(),
            inputPortName: captureService.currentInputPortName,
            inputPortType: AudioSessionManager().bestAvailableInput?.portType.rawValue ?? "unknown",
            routeChangeReason: "initial",
            sampleRate: nil
        )
        manifest = RecordingManifest(
            recordingId: itemId, title: recordingTitle,
            startedAt: Date(), segments: [firstSegment]
        )
        // Persist immediately — survives crash during recording
        saveManifest(manifest!, meetingId: itemId)

        AppLog.event("audio", "Recording started — itemID=\(itemId.uuidString.prefix(8)) input=\(captureService.currentInputPortName)")
            } catch AudioCaptureError.permissionDenied {
                AppLog.warn("audio", "Recording blocked: microphone permission denied")
                errorMessage = "Microphone access is off. Turn it on in Settings to record audio."
                rollbackItem(item, context: context)
            } catch AudioCaptureError.diskFull {
                AppLog.error("audio", "Recording failed: disk full")
                errorMessage = "Not enough storage. Free up space and try again."
                rollbackItem(item, context: context)
            } catch {
                let detail = error.localizedDescription
                AppLog.error("audio", "Recording start failed: \(detail)")
                errorMessage = "Could not start recording. Reason: \(detail)"
                rollbackItem(item, context: context)
            }
        }
    }

    func deleteItem(_ itemId: UUID) {
        let context = modelContext
        let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemId })
        if let item = try? context.fetch(descriptor).first {
            // Cascade delete annotations
            let annPred = FetchDescriptor<Annotation>(predicate: #Predicate { $0.itemID == itemId })
            if let anns = try? context.fetch(annPred) {
                for ann in anns { context.delete(ann) }
            }
            context.delete(item)
            try? context.save()
        }
        let store = FileArtifactStore()
        try? store.deleteMeetingDirectory(for: itemId)
    }

    func createItemFromImport(
        title: String,
        date: Date,
        duration: TimeInterval,
        projectID: UUID? = nil
    ) -> KnowledgeItem? {
        let context = modelContext
        let item = KnowledgeItem(type: .audio, title: title, createdAt: date, updatedAt: date, status: .recorded, durationSeconds: duration)
        item.audioFileRelativePath = AppFileConstants.audioFileName
        item.isImported = true
        if let pid = projectID { item.projectID = pid; item.inboxDate = nil }
        context.insert(item)
        try? context.save()
        return item
    }

    func pauseRecording() {
        // Pause in any active state — the capture service handles the transition.
        // Guard only against truly inactive states (idle, stopped).
        let isFailed: Bool = if case .failedFatal = state { true } else { false }
        guard state != .idle, state != .stopped, !isFailed else { return }

        captureService.pauseRecording()
        state = .pausedByUser
        pauseStartDate = Date()
        observationTimer?.invalidate()
        nowPlayingTimer?.invalidate()
        nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
        notifyStatusChange()
    }

    func resumeRecording() {
        guard state == .pausedByUser || state == .interruptedBySystem || state == .waitingForUsableInput || state == .reconfiguringRoute || state == .validatingRoute else { return }
        if state == .interruptedBySystem || state == .waitingForUsableInput {
            // Route-loss / interruption recovery — force recording intent
            retryRecordingRecovery()
            return
        }
        captureService.resumeRecording()
        // Only transition to .recording if the capture service actually recovered
        if captureService.state == .recording {
            commitUIRecordingState()
        } else {
            // Recovery failed — stay interrupted, timer remains frozen
            notifyStatusChange()
        }
    }

    func stopRecording() {
        // Accept ANY active state. Only refuse idle and stopped.
        guard state != .idle, state != .stopped else { return }
        let itemId = savedItemId
        AppLog.event("audio", "Stopping recording — elapsed=\(elapsedTimeFormatted) pausedDur=\(Int(pausedDuration))s itemID=\(itemId?.uuidString.prefix(8) ?? "nil")")
        captureService.stopRecording()
        state = .stopped
        nowPlayingController.deactivate()
        observationTimer?.invalidate()
        observationTimer = nil
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil

        // Finalize manifest — capture a copy so the pipeline closure below
        // can still access it after the if-var scope closes.
        var finalizedManifest: RecordingManifest? = nil
        if var m = manifest, let meetingId = savedItemId {
            if let idx = m.segments.indices.last { m.segments[idx].endedAt = Date() }
            m.endedAt = Date()
            saveManifest(m, meetingId: meetingId)
            finalizedManifest = m
        }

        if let pauseStart = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }

        // Update item — validates audio, marks as recorded or failed
        updateItemOnStop()
        notifyStatusChange()

        // Trigger pipeline AFTER concatenation and validation complete.
        // The Task is non-blocking for the UI (stop returns immediately),
        // but the pipeline is gated behind concat so audio.m4a is ready.
        if let itemId, let manifest = finalizedManifest {
            Task {
                // 1. Concatenate segments into audio.m4a (await, not fire-and-forget)
                await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)

                // 2. Debug validation report — mandatory until route switching is stable
                logRecordingArtifactReport(itemId: itemId)

                // 3. Route through ProcessingQueue when available — enables retry with
                //    backoff, offline queueing, and cancellation. Direct call is the
                //    fallback for backwards compatibility.
                if let queue = processingQueue {
                    AppLog.event("audio", "Enqueuing item \(itemId.uuidString.prefix(8)) into ProcessingQueue")
                    queue.enqueue(itemID: itemId, trigger: .newCapture)
                } else if let pipeline = contentPipeline {
                    AppLog.event("audio", "Pipeline (direct) for item \(itemId.uuidString.prefix(8))")
                    pipeline.process(itemId, using: modelContext)
                }
            }
        }
    }

    // MARK: - Segments

    /// Save the manifest to disk. Called after each segment and at stop.
    private func saveManifest(_ manifest: RecordingManifest, meetingId: UUID) {
        let store = FileArtifactStore()
        try? store.writeRecordingManifest(manifest, for: meetingId)
    }

    func returnToIdle() {
        state = .idle
        elapsedTime = 0
        pausedDuration = 0
        audioLevel = 0
        isClipping = false
        clipCount = 0
        isAutoPaused = false
        silenceDetected = false
        savedItemId = nil
        errorMessage = nil
        captureService.resetToIdle()
    }

    // MARK: - State sync with capture service

    /// Atomically commit the UI to `.recording`. The capture service has already
    /// validated that the engine is running and buffers are arriving. This is
    /// the ONLY path that sets coordinator state to `.recording` from sync.
    private func commitUIRecordingState() {
        if let ps = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(ps)
            pauseStartDate = nil
        }
        state = .recording
        startObservation()
        nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: true)
        notifyStatusChange()
    }

    /// Mirror the capture service's real state. The capture service owns the
    /// source of truth for recording state — this coordinator mirrors it for UI.
    private func syncCaptureState(_ captureState: AudioCaptureState) {
        switch captureState {
        case .recording:
            // Only auto-transition from non-user-paused states.
            let shouldAutoResume = state == .waitingForUsableInput
                || state == .interruptedBySystem
                || state == .reconfiguringRoute
                || state == .validatingRoute
            if shouldAutoResume {
                commitUIRecordingState()
            }
        case .reconfiguringRoute, .validatingRoute:
            if state == .recording || state == .pausedByUser || state == .reconfiguringRoute {
                // Stop timer but keep logical recording alive
                if pauseStartDate == nil { pauseStartDate = Date() }
                observationTimer?.invalidate()
                nowPlayingTimer?.invalidate()
                state = captureState == .validatingRoute ? .validatingRoute : .reconfiguringRoute
                nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
                notifyStatusChange()
            }
        case .waitingForUsableInput:
            if state == .recording || state == .pausedByUser || state == .reconfiguringRoute {
                if pauseStartDate == nil { pauseStartDate = Date() }
                observationTimer?.invalidate()
                nowPlayingTimer?.invalidate()
                state = .waitingForUsableInput
                nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
                notifyStatusChange()
            }
        case .interruptedBySystem:
            if state == .recording || state == .pausedByUser {
                state = .interruptedBySystem
                if pauseStartDate == nil { pauseStartDate = Date() }
                observationTimer?.invalidate()
                nowPlayingTimer?.invalidate()
                nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
                notifyStatusChange()
            }
        case .pausedByUser:
            if state == .recording {
                state = .pausedByUser
                if pauseStartDate == nil { pauseStartDate = Date() }
                observationTimer?.invalidate()
                notifyStatusChange()
            }
        case .stopped:
            if state != .stopped {
                state = .stopped
                observationTimer?.invalidate()
                nowPlayingTimer?.invalidate()
                notifyStatusChange()
            }
        case .failedFatal(let message):
            let isAlreadyFailed: Bool = if case .failedFatal = state { true } else { false }
            if !isAlreadyFailed || errorMessage != message {
                state = .failedFatal(message)
                errorMessage = message
                observationTimer?.invalidate()
                nowPlayingTimer?.invalidate()
                nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
                notifyStatusChange()
            }
        case .idle:
            break
        }
    }

    /// Force recovery using the built-in iPhone microphone.
    /// Call when Bluetooth fails and the user wants to fall back.
    func forceBuiltInMicRecovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.captureService.forceBuiltInMicRecovery()
            if self.captureService.state == .recording {
                self.commitUIRecordingState()
            }
        }
    }

    /// Manual retry when the user presses Resume after a route-loss interruption.
    /// Forces .recording intent with up to 3 attempts and progressive delay —
    /// Bluetooth devices take time to stabilize after connection.
    func retryRecordingRecovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                await self.captureService.attemptResume(forceRecording: true)

                if self.captureService.state == .recording {
                    self.commitUIRecordingState()
                    AppLog.audio.info("Recording resumed after \(attempt) attempt(s)")
                    return
                }

                // Don't retry if the failure is permanent (not a transient Bluetooth issue)
                let reason = self.captureService.audioInterruptionReason ?? ""
                if reason.contains("storage") || reason.contains("Internal error") {
                    break
                }

                if attempt < 3 {
                    let delayNs = UInt64(attempt) * 700_000_000
                    AppLog.audio.info("Resume attempt \(attempt) failed — retrying in \(delayNs / 1_000_000)ms")
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            }

            self.state = .waitingForUsableInput
            self.errorMessage = self.captureService.audioInterruptionReason
                ?? "Could not resume recording. Try disconnecting Bluetooth or use iPhone mic."
            self.notifyStatusChange()
        }
    }

    /// Attempt to recover from audio interruptions when the app returns to the foreground.
    func onAppForeground() {
        guard state == .interruptedBySystem || state == .waitingForUsableInput else { return }
        AppLog.event("audio", "App returned to foreground while interrupted — attempting recovery")
        captureService.resumeRecording()
        if captureService.state == .recording {
            state = .recording
            startObservation()
            notifyStatusChange()
        } else if captureService.state == .pausedByUser {
            state = .pausedByUser
            notifyStatusChange()
        }
    }

    /// Remove any recording directories for items that are still in .recording status
    /// (abandoned from previous app termination). Call once at app startup.
    /// Uses a dedicated background context to avoid touching the main context during init.
    func cleanupOrphanedRecordings() {
        // Use a fresh context isolated from the main context used by SwiftUI views.
        // This is a read-delete-save driven by app init, not user interaction.
        do {
            let bgContext = ModelContext(modelContext.container)
            let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.statusRaw == "recording" })
            guard let orphans = try? bgContext.fetch(descriptor), !orphans.isEmpty else { return }

            AppLog.audio.info("Found \(orphans.count) interrupted recording(s) — recovering")
            var recoveredIds: [UUID] = []
            for item in orphans {
                AppLog.audio.info("Recovering interrupted recording: \(item.id)")
                item.status = .recorded
                // Prefer manifest for new segmented recordings, fall back to audio.m4a
                let store = FileArtifactStore()
                if store.recordingManifestExists(for: item.id) {
                    item.audioFileRelativePath = AppFileConstants.manifestFileName
                } else if store.audioFileExists(for: item.id) {
                    item.audioFileRelativePath = AppFileConstants.audioFileName
                } else {
                    item.status = .failed
                    continue
                }
                recoveredIds.append(item.id)
            }
            try bgContext.save()
            AppLog.audio.info("Recovered \(recoveredIds.count)/\(orphans.count) interrupted recording(s)")

            // Trigger pipeline for successfully recovered items so they get
            // transcribed and analyzed. Without this, crash-recovered items
            // remain stuck in .recorded state forever.
            if !recoveredIds.isEmpty {
                for itemId in recoveredIds {
                    AppLog.event("audio", "Enqueuing recovered item \(itemId.uuidString.prefix(8)) for pipeline processing")
                    // Use Task to avoid blocking app init — pipeline runs async.
                    Task { @MainActor in
                        // Concatenate segments first (essential for multi-segment recordings)
                        if let m = try? FileArtifactStore().readRecordingManifest(for: itemId) {
                            await AudioSegmentConcatenator.concatenate(manifest: m, meetingId: itemId)
                        }
                        if let queue = processingQueue {
                            queue.enqueue(itemID: itemId, trigger: .newCapture)
                        } else if let pipeline = contentPipeline {
                            pipeline.process(itemId, using: modelContext)
                        }
                    }
                }
            }
        } catch {
            AppLog.audio.error("Orphan cleanup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Status

    func currentStatus() -> RecordingStatus {
        RecordingStatus(
            state: stateString,
            elapsedTime: elapsedTime - pausedDuration,
            audioLevel: audioLevel,
            errorMessage: errorMessage,
            recordingTitle: recordingTitle,
            isActive: state == .recording || state == .pausedByUser || state == .interruptedBySystem || state == .waitingForUsableInput
        )
    }

    private var stateString: String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .pausedByUser: return "paused"
        case .reconfiguringRoute: return "reconfiguring"
        case .validatingRoute: return "validating"
        case .waitingForUsableInput: return "waitingForInput"
        case .interruptedBySystem: return "interrupted"
        case .failedFatal: return "failed"
        case .stopped: return "stopped"
        }
    }

    private func notifyStatusChange() {
        let status = currentStatus()
        onStatusChange?(status)
        if let shared = UserDefaults(suiteName: "group.com.wawa-note") {
            shared.set(status.state, forKey: "recordingState")
            shared.set(status.elapsedTime, forKey: "elapsedTime")
            shared.set(status.isActive, forKey: "isActive")
            shared.set(status.recordingTitle, forKey: "recordingTitle")
        }
    }

    // MARK: - Lock screen controls

    private func activateLockScreenControls() {
        nowPlayingController.onPlay = { [weak self] in
            DispatchQueue.main.async { self?.resumeRecording() }
        }
        nowPlayingController.onPause = { [weak self] in
            DispatchQueue.main.async { self?.pauseRecording() }
        }
        nowPlayingController.onStop = { [weak self] in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        nowPlayingController.onTogglePlayPause = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.state == .recording {
                    self.pauseRecording()
                } else if self.state == .pausedByUser {
                    self.resumeRecording()
                }
            }
        }
        nowPlayingController.activate()
        nowPlayingController.update(title: recordingTitle, elapsedTime: 0, isPlaying: true)
    }

    // MARK: - Observation

    private func startObservation() {
        // Timer.scheduledTimer MUST be created on the main thread — otherwise
        // it fires on a background run loop and triggers BUG IN CLIENT OF LIBDISPATCH
        // in MPNowPlayingInfoCenter, which asserts on the main-thread requirement.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startObservation() }
            return
        }

        observationTimer?.invalidate()
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer.scheduledTimer fires on main run loop — already on main thread.
            if let start = self.recordingStartDate {
                self.elapsedTime = Date().timeIntervalSince(start)
            }
            self.audioLevel = self.captureService.audioLevel
            // Clipping detection (hysteresis: on at > 0.95, off at < 0.85)
            let level = self.captureService.audioLevel
            if level > 0.95 && !self.isClipping {
                self.isClipping = true
                self.clipCount += 1
            } else if level < 0.85 && self.isClipping {
                self.isClipping = false
            }
            // Sync auto-pause / silence state from capture service
            if self.isAutoPaused != self.captureService.isAutoPaused {
                self.isAutoPaused = self.captureService.isAutoPaused
            }
            if self.silenceDetected != self.captureService.silenceDetected {
                self.silenceDetected = self.captureService.silenceDetected
            }
            // Sync input port info (may change on route switch)
            // Segments are handled by onRouteChangeNewSegment callback
            let portName = self.captureService.currentInputPortName
            if self.currentInputPortName != portName, !portName.isEmpty {
                self.currentInputPortName = portName
                self.currentInputIcon = AudioSessionManager().currentInputIcon
            }
            if self.captureService.state == .stopped {
                self.state = .stopped
                self.nowPlayingController.deactivate()
                self.observationTimer?.invalidate()
                self.observationTimer = nil
                self.nowPlayingTimer?.invalidate()
                self.nowPlayingTimer = nil
            } else if (self.captureService.state == .interruptedBySystem || self.captureService.state == .waitingForUsableInput) && self.state != .waitingForUsableInput && self.state != .interruptedBySystem {
                self.state = .waitingForUsableInput
                self.pauseStartDate = Date()  // Freeze elapsed time
                self.notifyStatusChange()
            }
        }

        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer.scheduledTimer fires on main run loop — already on main thread.
            guard self.state == .recording || self.state == .pausedByUser else { return }
            let effective = self.elapsedTime - self.pausedDuration
            self.nowPlayingController.update(
                title: self.recordingTitle,
                elapsedTime: effective,
                isPlaying: self.state == .recording
            )
        }
    }

    // MARK: - Context capture

    private func captureContextSafely(for itemId: UUID) {
        let sensors = contextCaptureService
        let annotSvc = annotationService
        Task.detached {
            let captured = await sensors.captureAll()
            guard !captured.isEmpty else { return }
            await MainActor.run {
                do {
                    try annotSvc.upsert(captured, itemID: itemId, source: "recording_context")
                    AppLog.general.info("Context: \(captured.count) annotations for item \(itemId)")
                } catch {
                    AppLog.error("general", "Context capture save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func rollbackItem(_ item: KnowledgeItem, context: ModelContext) {
        context.delete(item)
        do {
            try context.save()
        } catch {
            AppLog.error("audio", "Failed to rollback item after recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Debug

    /// Log a structured recording artifact report. Mandatory until route switching is stable.
    /// Called on every Finish after concatenation completes.
    private func logRecordingArtifactReport(itemId: UUID) {
        let store = FileArtifactStore()
        let report = store.debugRecordingArtifacts(meetingId: itemId)
        AppLog.audio.info("RecordingArtifactValidation:\n\(report)")
    }

    // MARK: - Save

    /// Validate that at least one segment in the manifest has a real file with audio data.
    private func hasValidAudioData(meetingId: UUID) -> Bool {
        let store = FileArtifactStore()
        guard store.recordingManifestExists(for: meetingId),
              let manifest = try? store.readRecordingManifest(for: meetingId) else {
            // Legacy: check audio.m4a directly
            return store.audioFileExists(for: meetingId)
        }
        for seg in manifest.segments {
            let url = store.segmentURL(for: meetingId, fileName: seg.fileName)
            if FileManager.default.fileExists(atPath: url.path),
               let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
               size > 0 {
                return true
            }
        }
        return false
    }

    private func updateItemOnStop() {
        let context = modelContext
        guard let itemId = savedItemId else { return }

        let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemId })
        guard let item = try? context.fetch(descriptor).first else { return }

        let effectiveDuration = elapsedTime - pausedDuration
        let hasAudio = hasValidAudioData(meetingId: itemId)

        if hasAudio {
            item.status = .recorded
            item.durationSeconds = effectiveDuration
            // Prefer manifest for segmented recordings, audio.m4a for legacy
            item.audioFileRelativePath = FileArtifactStore().recordingManifestExists(for: itemId)
                ? AppFileConstants.manifestFileName
                : AppFileConstants.audioFileName
            AppLog.audio.info("Item finalized: \(item.id) hasAudio=true duration=\(effectiveDuration)s")
        } else {
            // No valid audio data found — mark as failed, don't pretend it was recorded
            item.status = .failed
            AppLog.audio.warning("Item finalized: \(item.id) hasAudio=false — marking as failed")
        }

        do {
            try context.save()
            AppLog.audio.info("Item updated: \(item.id)")
        } catch {
            AppLog.error("audio", "Failed to save item update: \(error.localizedDescription)")
        }
    }
}
