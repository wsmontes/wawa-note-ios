import SwiftData
import OSLog

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingUIState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedItemId: UUID?

    private let captureService: AudioCaptureService
    private let nowPlayingController: NowPlayingController
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext
    private let contextCaptureService = ContextCaptureService()
    private var annotationService: AnnotationService

    private var recordingStartDate: Date?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartDate: Date?
    private var meetingTitle: String = ""
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
        projectID: UUID? = nil
    ) {
        guard self.state == .idle else {
            AppLog.audio.warning("RecordingCoordinator: startRecording called but state is \(String(describing: self.state))")
            return
        }

        let context = modelContext
        errorMessage = nil
        savedItemId = nil

        let meetingTitle = title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        self.meetingTitle = meetingTitle

        let item = KnowledgeItem(type: .meeting, title: meetingTitle, status: .recording)
        item.scheduledDate = scheduledDate
        item.calendarEventIdentifier = calendarEventIdentifier
        if let projectID { item.projectID = projectID; item.inboxDate = nil }
        context.insert(item)

        do {
            try context.save()
        } catch {
            AppLog.audio.error("Failed to save knowledge item: \(error)")
            errorMessage = "Could not save meeting. Try again."
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
            } catch AudioCaptureError.permissionDenied {
                errorMessage = "Microphone access is off. Turn it on in Settings to record meetings."
                rollbackItem(item, context: context)
            } catch {
                errorMessage = "Could not start recording."
                rollbackItem(item, context: context)
                AppLog.audio.error("Recording start failed: \(error.localizedDescription)")
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
        duration: TimeInterval
    ) -> KnowledgeItem? {
        let context = modelContext

        let item = KnowledgeItem(type: .meeting, title: title, createdAt: date, updatedAt: date,
                                  status: .recorded, durationSeconds: duration)
        item.audioFileRelativePath = AppFileConstants.audioFileName
        item.isImported = true
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
        nowPlayingController.update(title: meetingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: false)
        notifyStatusChange()
    }

    func resumeRecording() {
        guard state == .paused else { return }
        captureService.resumeRecording()
        state = .recording
        if let pauseStart = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }
        pauseStartDate = nil
        nowPlayingController.update(title: meetingTitle, elapsedTime: elapsedTime - pausedDuration, isPlaying: true)
        startObservation()
        notifyStatusChange()
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        captureService.stopRecording()
        state = .stopped
        nowPlayingController.deactivate()
        observationTimer?.invalidate()
        observationTimer = nil
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil

        if let pauseStart = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }

        updateItemOnStop()
        notifyStatusChange()
    }

    func returnToIdle() {
        state = .idle
        elapsedTime = 0
        pausedDuration = 0
        audioLevel = 0
        savedItemId = nil
        errorMessage = nil
    }

    // MARK: - Status

    func currentStatus() -> RecordingStatus {
        RecordingStatus(
            state: stateString,
            elapsedTime: elapsedTime - pausedDuration,
            audioLevel: audioLevel,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle,
            isActive: state == .recording || state == .paused
        )
    }

    private var stateString: String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .paused: return "paused"
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
            shared.set(status.meetingTitle, forKey: "meetingTitle")
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
        nowPlayingController.update(title: meetingTitle, elapsedTime: 0, isPlaying: true)
    }

    // MARK: - Observation

    private func startObservation() {
        observationTimer?.invalidate()
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let start = self.recordingStartDate {
                    self.elapsedTime = Date().timeIntervalSince(start)
                }
                self.audioLevel = self.captureService.audioLevel
                if self.captureService.state == .stopped {
                    self.state = .stopped
                    self.nowPlayingController.deactivate()
                    self.observationTimer?.invalidate()
                    self.observationTimer = nil
                    self.nowPlayingTimer?.invalidate()
                    self.nowPlayingTimer = nil
                }
            }
        }

        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.state == .recording || self.state == .paused else { return }
                let effective = self.elapsedTime - self.pausedDuration
                self.nowPlayingController.update(
                    title: self.meetingTitle,
                    elapsedTime: effective,
                    isPlaying: self.state == .recording
                )
            }
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
                    AppLog.general.error("Context capture save failed: \(error)")
                }
            }
        }
    }

    private func rollbackItem(_ item: KnowledgeItem, context: ModelContext) {
        context.delete(item)
        do {
            try context.save()
        } catch {
            AppLog.audio.error("Failed to rollback item: \(error)")
        }
    }

    // MARK: - Save

    private func updateItemOnStop() {
        let context = modelContext
        guard let itemId = savedItemId else { return }

        let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemId })
        guard let item = try? context.fetch(descriptor).first else { return }

        let effectiveDuration = elapsedTime - pausedDuration
        item.status = .recorded
        item.durationSeconds = effectiveDuration
        item.audioFileRelativePath = AppFileConstants.audioFileName

        do {
            try context.save()
            AppLog.audio.info("Item updated: \(item.id)")
        } catch {
            AppLog.audio.error("Failed to save item update: \(error)")
        }
    }
}
