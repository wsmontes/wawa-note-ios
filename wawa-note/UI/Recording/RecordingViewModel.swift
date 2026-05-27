import Combine
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
    @Published var isPlaying = false
    @Published var playbackCurrentTime: TimeInterval = 0

    private let coordinator: RecordingCoordinator
    private let playbackService: AudioPlaybackService
    private var playbackObservationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    // Forwarded from coordinator — RecordView observes these via the VM.
    var state: RecordingUIState { coordinator.state }
    var elapsedTime: TimeInterval { coordinator.elapsedTime }
    var audioLevel: Float { coordinator.audioLevel }
    var errorMessage: String? { coordinator.errorMessage }
    var savedMeetingId: UUID? { coordinator.savedMeetingId }

    var elapsedTimeFormatted: String { coordinator.elapsedTimeFormatted }

    var playbackTimeFormatted: String {
        let minutes = Int(playbackCurrentTime) / 60
        let seconds = Int(playbackCurrentTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    init(
        coordinator: RecordingCoordinator,
        playbackService: AudioPlaybackService = AudioPlaybackService()
    ) {
        self.coordinator = coordinator
        self.playbackService = playbackService

        // Forward coordinator changes so RecordView re-renders.
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Recording

    func startRecording(
        title: String? = nil,
        scheduledDate: Date? = nil,
        calendarEventIdentifier: String? = nil
    ) {
        coordinator.startRecording(
            title: title,
            scheduledDate: scheduledDate,
            calendarEventIdentifier: calendarEventIdentifier
        )
    }
    func pauseRecording() { coordinator.pauseRecording() }
    func resumeRecording() { coordinator.resumeRecording() }
    func stopRecording() { coordinator.stopRecording() }

    // MARK: - Markers

    func markImportant() {
        AppLog.audio.info("Important moment marked at \(self.elapsedTimeFormatted)")
    }

    // MARK: - Playback

    func startPlayback() {
        guard let url = coordinator.outputFileURL else { return }
        do {
            try playbackService.load(url: url)
            playbackService.play()
            isPlaying = true
            observePlayback()
        } catch {
            // Playback errors are non-critical; log and move on.
            AppLog.audio.error("Playback start failed: \(error.localizedDescription)")
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
        playbackObservationTask?.cancel()
    }

    // MARK: - Playback observation

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
}
