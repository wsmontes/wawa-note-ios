import SwiftUI
import SwiftData

enum RecordingUIState {
    case idle
    case recording
    case paused
    case stopped
}

@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var state: RecordingUIState = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?
    @Published var savedMeetingId: UUID?

    @Published var isPlaying = false
    @Published var playbackCurrentTime: TimeInterval = 0

    private let captureService: AudioCaptureService
    private let playbackService: AudioPlaybackService
    private var modelContext: ModelContext?
    private var recordingStartDate: Date?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartDate: Date?

    var elapsedTimeFormatted: String {
        let effective = elapsedTime - pausedDuration
        let m = Int(effective) / 60
        let s = Int(effective) % 60
        return String(format: "%02d:%02d", m, s)
    }

    var playbackTimeFormatted: String {
        let minutes = Int(playbackCurrentTime) / 60
        let seconds = Int(playbackCurrentTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    init(
        captureService: AudioCaptureService = AudioCaptureService(),
        playbackService: AudioPlaybackService = AudioPlaybackService()
    ) {
        self.captureService = captureService
        self.playbackService = playbackService
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Recording

    func startRecording() {
        guard let context = modelContext else { return }
        errorMessage = nil
        savedMeetingId = nil

        let meeting = MeetingModel(
            title: "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        )
        meeting.status = .recording
        context.insert(meeting)
        try? context.save()

        let meetingId = meeting.id
        savedMeetingId = meetingId

        Task {
            do {
                try await captureService.startRecording(meetingId: meetingId)
                recordingStartDate = Date()
                state = .recording
                observeCaptureState()
            } catch AudioCaptureError.permissionDenied {
                errorMessage = "Microphone access is off. Turn it on in Settings to record meetings."
                context.delete(meeting)
                try? context.save()
            } catch {
                errorMessage = "Could not start recording."
                context.delete(meeting)
                try? context.save()
                AppLog.audio.error("Recording start failed: \(error.localizedDescription)")
            }
        }
    }

    func pauseRecording() {
        captureService.pauseRecording()
        state = .paused
        pauseStartDate = Date()
        observationTimer?.invalidate()
    }

    func resumeRecording() {
        do {
            try captureService.resumeRecording()
            state = .recording
            if let pauseStart = pauseStartDate {
                pausedDuration += Date().timeIntervalSince(pauseStart)
            }
            pauseStartDate = nil
            observeCaptureState()
        } catch {
            errorMessage = "Could not resume recording."
        }
    }

    func stopRecording() {
        captureService.stopRecording()
        state = .stopped

        if let pauseStart = pauseStartDate {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }
        updateMeetingOnStop()
    }

    // MARK: - Markers

    func markImportant() {
        AppLog.audio.info("Important moment marked at \(self.elapsedTimeFormatted)")
    }

    // MARK: - Playback

    func startPlayback() {
        guard let url = captureService.outputFileURL else { return }
        do {
            try playbackService.load(url: url)
            playbackService.play()
            isPlaying = true
            observePlayback()
        } catch {
            errorMessage = "Could not play audio file."
        }
    }

    func pausePlayback() {
        playbackService.pause()
        isPlaying = false
    }

    func resumePlayback() {
        playbackService.resume()
        isPlaying = true
    }

    func stopPlayback() {
        playbackService.stop()
        isPlaying = false
        playbackCurrentTime = 0
    }

    // MARK: - Observation

    private var observationTimer: Timer?
    private var playbackObservationTask: Task<Void, Never>?

    private func observeCaptureState() {
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
                    self.observationTimer?.invalidate()
                    self.observationTimer = nil
                }
            }
        }
    }

    private func observePlayback() {
        playbackObservationTask?.cancel()
        playbackObservationTask = Task { [weak self] in
            guard let self else { return }
            let times = self.playbackService.$currentTime.values
            let states = self.playbackService.$state.values

            var timeIt = times.makeAsyncIterator()
            var stateIt = states.makeAsyncIterator()

            while !Task.isCancelled {
                if let time = await timeIt.next() { self.playbackCurrentTime = time }
                if let pbState = await stateIt.next() {
                    if pbState == .finished || pbState == .idle {
                        self.isPlaying = false
                        if pbState == .finished { self.playbackCurrentTime = 0 }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
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
