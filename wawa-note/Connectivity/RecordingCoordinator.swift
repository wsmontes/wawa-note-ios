import SwiftData
import OSLog
@preconcurrency import ActivityKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingUIState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedItemId: UUID?
    @Published private(set) var currentInputPortName: String = ""
    @Published private(set) var currentInputIcon: String = "mic.fill"

    private let captureService: AudioCaptureService
    private let nowPlayingController: NowPlayingController
    private nonisolated(unsafe) var liveActivity: Activity<RecordingActivityAttributes>?
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext
    private let contextCaptureService = ContextCaptureService()
    private var annotationService: AnnotationService
    var contentPipeline: ContentPipelineService?

    private var recordingStartDate: Date?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartDate: Date?
    private var recordingTitle: String = ""
    private var observationTimer: Timer?
    private var nowPlayingTimer: Timer?

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
    }

    // MARK: - Recording lifecycle

    func startRecording(
        title: String? = nil,
        scheduledDate: Date? = nil,
        calendarEventIdentifier: String? = nil,
        projectID: UUID? = nil,
        profile: CaptureProfile = .voiceMemo
    ) {
        // Auto-recover from stale state: if previous recording ended
        // but finishCapture() wasn't called, force-reset to idle.
        if self.state == .stopped {
            AppLog.warn("audio", "RecordingCoordinator: state was .stopped — auto-resetting to idle")
            returnToIdle()
        }
        guard self.state == .idle else {
            AppLog.warn("audio", "RecordingCoordinator: startRecording called but state is \(String(describing: self.state)) — ignoring")
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
                AppLog.error("audio", "Recording start failed: \(error.localizedDescription)")
                errorMessage = "Could not start recording."
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
        guard state == .recording else { return }
        captureService.pauseRecording()
        state = .paused
        pauseStartDate = Date()
        observationTimer?.invalidate()
        nowPlayingTimer?.invalidate()
        nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
        notifyStatusChange()
    }

    func resumeRecording() {
        guard state == .paused || state == .interrupted else { return }
        captureService.resumeRecording()
        state = .recording
        if let pauseStart = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }
        pauseStartDate = nil
        nowPlayingController.update(title: recordingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: true)
        startObservation()
        notifyStatusChange()
    }

    func stopRecording() {
        guard state == .recording || state == .paused || state == .interrupted else { return }
        AppLog.event("audio", "Stopping recording — elapsed=\(elapsedTimeFormatted) pausedDur=\(Int(pausedDuration))s itemID=\(savedItemId?.uuidString.prefix(8) ?? "nil")")
        captureService.stopRecording()
        state = .stopped
        nowPlayingController.deactivate()
        stopLiveActivity()
        observationTimer?.invalidate()
        observationTimer = nil
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil

        if let pauseStart = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }

        updateItemOnStop()
        notifyStatusChange()

        // Pipeline is launched by CaptureViewModel.stopRecording() which owns
        // the recording lifecycle. RecordingCoordinator just manages audio state.
    }

    func returnToIdle() {
        state = .idle
        elapsedTime = 0
        pausedDuration = 0
        audioLevel = 0
        savedItemId = nil
        errorMessage = nil
        captureService.resetToIdle()
    }

    /// Attempt to recover from audio interruptions when the app returns to the foreground.
    func onAppForeground() {
        guard state == .interrupted else { return }
        AppLog.event("audio", "App returned to foreground while interrupted — attempting recovery")
        captureService.resumeRecording()
        if captureService.state == .recording {
            state = .recording
            startObservation()
            notifyStatusChange()
        } else if captureService.state == .paused {
            state = .paused
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
            for item in orphans {
                AppLog.audio.info("Recovering interrupted recording: \(item.id)")
                item.status = .recorded
                item.audioFileRelativePath = AppFileConstants.audioFileName
            }
            try bgContext.save()
            AppLog.audio.info("Recovered \(orphans.count) interrupted recording(s) — saved as recorded")
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
            isActive: state == .recording || state == .paused || state == .interrupted
        )
    }

    private var stateString: String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .paused: return "paused"
        case .interrupted: return "interrupted"
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
                } else if self.state == .paused {
                    self.resumeRecording()
                }
            }
        }
        nowPlayingController.activate()
        nowPlayingController.update(title: recordingTitle, elapsedTime: 0, isPlaying: true)
        startLiveActivity()
    }

    // MARK: - Observation

    private func startObservation() {
        observationTimer?.invalidate()
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer.scheduledTimer fires on main run loop — already on main thread.
            if let start = self.recordingStartDate {
                self.elapsedTime = Date().timeIntervalSince(start)
            }
            self.audioLevel = self.captureService.audioLevel
            // Sync input port info (may change on route switch)
            let portName = self.captureService.currentInputPortName
            if self.currentInputPortName != portName {
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
            } else if self.captureService.state == .interrupted && self.state != .interrupted {
                self.state = .interrupted
                self.notifyStatusChange()
            }
        }

        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer.scheduledTimer fires on main run loop — already on main thread.
            guard self.state == .recording || self.state == .paused else { return }
            let effective = self.elapsedTime - self.pausedDuration
            self.nowPlayingController.update(
                title: self.recordingTitle,
                elapsedTime: effective,
                isPlaying: self.state == .recording
            )
            self.updateLiveActivity(effective: effective)
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

    // MARK: - Live Activity

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = RecordingActivityAttributes()
        let state = RecordingActivityAttributes.ContentState(
            elapsedTimeFormatted: "00:00",
            isPaused: false,
            title: recordingTitle
        )
        do {
            liveActivity = try Activity<RecordingActivityAttributes>.request(
                attributes: attrs,
                contentState: state,
                pushType: nil
            )
        } catch {
            AppLog.warn("general", "LiveActivity start failed: \(error.localizedDescription)")
        }
    }

    private func updateLiveActivity(effective: TimeInterval) {
        guard let activity = liveActivity else { return }
        let mm = Int(effective) / 60
        let ss = Int(effective) % 60
        let formatted = String(format: "%02d:%02d", mm, ss)
        let state = RecordingActivityAttributes.ContentState(
            elapsedTimeFormatted: formatted,
            isPaused: state == .paused,
            title: recordingTitle
        )
        Task { @MainActor [activity] in await activity.update(using: state) }
    }

    private func stopLiveActivity() {
        guard let activity = liveActivity else { return }
        let state = RecordingActivityAttributes.ContentState(
            elapsedTimeFormatted: "00:00",
            isPaused: false,
            title: "Recording ended"
        )
        Task { @MainActor [activity] in await activity.end(using: state, dismissalPolicy: .immediate) }
        liveActivity = nil
    }

    // MARK: - Save

    private func updateItemOnStop() {
        let context = modelContext
        guard let itemId = savedItemId else { return }

        let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemId })
        guard let item = try? context.fetch(descriptor).first else { return }

        let effectiveDuration = elapsedTime - pausedDuration
        item.durationSeconds = effectiveDuration
        item.audioFileRelativePath = AppFileConstants.audioFileName

        // Check if the audio file writer had errors — if so, mark as failed
        if captureService.hasWriteErrors {
            AppLog.error("audio", "Recording stopped with write errors — file may be corrupted. Marking as failed.")
            item.status = .failed
            errorMessage = "Recording file may be corrupted. Write errors occurred during recording."
        } else {
            item.status = .recorded
        }

        do {
            try context.save()
            AppLog.audio.info("Item \(item.id) updated: status=\(item.status.rawValue) duration=\(Int(effectiveDuration))s")
        } catch {
            AppLog.error("audio", "Failed to save item update: \(error.localizedDescription)")
        }
    }
}

// MARK: - Live Activity Attributes

struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedTimeFormatted: String
        var isPaused: Bool
        var title: String
    }
}
