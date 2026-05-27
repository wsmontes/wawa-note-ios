import SwiftData
import OSLog

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingUIState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedMeetingId: UUID?

    private let captureService: AudioCaptureService
    private let nowPlayingController: NowPlayingController
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext?

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
        self.modelContext = ModelContext(modelContainer)
    }

    // MARK: - Recording lifecycle

    func startRecording(
        title: String? = nil,
        scheduledDate: Date? = nil,
        calendarEventIdentifier: String? = nil
    ) {
        guard self.state == .idle else {
            AppLog.audio.warning("RecordingCoordinator: startRecording called but state is \(String(describing: self.state))")
            return
        }

        guard let context = modelContext else { return }
        errorMessage = nil
        savedMeetingId = nil

        let meetingTitle = title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        self.meetingTitle = meetingTitle

        let meeting = MeetingModel(title: meetingTitle)
        meeting.status = .recording
        meeting.scheduledDate = scheduledDate
        meeting.calendarEventIdentifier = calendarEventIdentifier
        context.insert(meeting)
        try? context.save()

        let meetingId = meeting.id
        savedMeetingId = meetingId

        Task {
            do {
                try await captureService.startRecording(meetingId: meetingId)
                recordingStartDate = Date()
                state = .recording
                activateLockScreenControls()
                startObservation()
                notifyStatusChange()
            } catch AudioCaptureError.permissionDenied {
                errorMessage = "Microphone access is off. Turn it on in Settings to record meetings."
                context.delete(meeting)
                try? context.save()
                notifyStatusChange()
            } catch {
                errorMessage = "Could not start recording."
                context.delete(meeting)
                try? context.save()
                AppLog.audio.error("Recording start failed: \(error.localizedDescription)")
                notifyStatusChange()
            }
        }
    }

    func deleteMeeting(_ meeting: MeetingModel) {
        guard let context = modelContext else { return }
        context.delete(meeting)
        try? context.save()
        // Clean up artifacts
        let store = FileArtifactStore()
        try? store.deleteMeetingDirectory(for: meeting.id)
    }

    func createMeetingFromImport(
        title: String,
        date: Date,
        duration: TimeInterval
    ) -> MeetingModel? {
        guard let context = modelContext else { return nil }

        let meeting = MeetingModel(
            title: title,
            createdAt: date,
            updatedAt: date,
            durationSeconds: duration,
            status: .recorded,
            isImported: true
        )
        meeting.audioFileRelativePath = "audio.m4a"
        context.insert(meeting)
        try? context.save()

        return meeting
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

        updateMeetingOnStop()
        notifyStatusChange()
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
        // Also write to App Group for watch complication
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
            MainActor.assumeIsolated {
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
            MainActor.assumeIsolated {
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

    // MARK: - Save

    private func updateMeetingOnStop() {
        guard let context = modelContext else { return }
        guard let meetingId = savedMeetingId else { return }

        let descriptor = FetchDescriptor<MeetingModel>(predicate: #Predicate { $0.id == meetingId })
        guard let meeting = try? context.fetch(descriptor).first else { return }

        meeting.status = .recorded
        meeting.durationSeconds = elapsedTime - pausedDuration
        meeting.audioFileRelativePath = "audio.m4a"

        try? context.save()
        AppLog.audio.info("Meeting updated: \(meeting.id)")
    }
}
