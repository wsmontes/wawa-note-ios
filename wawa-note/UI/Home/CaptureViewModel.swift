import SwiftUI
import Combine

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var recordingState: RecordingUIState = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var elapsedTimeFormatted: String = "00:00"
    @Published var errorMessage: String?
    @Published var savedItemId: UUID?
    @Published var pipelineStage: PipelineStage?

    enum PipelineStage: String {
        case saving = "Saving audio..."
        case transcribing = "Transcribing..."
        case analyzing = "Analyzing..."
        case ready = "Ready"
    }

    private var coordinator: RecordingCoordinator?
    private var cancellables: Set<AnyCancellable> = []

    init() {}

    func bind(coordinator: RecordingCoordinator) {
        guard self.coordinator == nil else { return }
        self.coordinator = coordinator
        pullState()
        coordinator.objectWillChange.sink { [weak self] _ in self?.pullState() }
            .store(in: &cancellables)
    }

    private func pullState() {
        guard let c = coordinator else { return }
        recordingState = c.state
        elapsedTime = c.elapsedTime
        audioLevel = c.audioLevel
        elapsedTimeFormatted = c.elapsedTimeFormatted
        errorMessage = c.errorMessage
        savedItemId = c.savedItemId
    }

    // MARK: - Actions

    func startRecording(title: String? = nil) {
        pipelineStage = nil
        coordinator?.startRecording(title: title)
    }

    func pauseRecording() { coordinator?.pauseRecording() }
    func resumeRecording() { coordinator?.resumeRecording() }

    func stopRecording() {
        coordinator?.stopRecording()
        Task { await runPipeline() }
    }

    func finishCapture() {
        pipelineStage = nil
        savedItemId = nil
        errorMessage = nil
        // Reset coordinator state back to idle so user returns to default surface
        coordinator?.returnToIdle()
    }

    // MARK: - Pipeline

    private func runPipeline() async {
        pipelineStage = .saving
        try? await Task.sleep(nanoseconds: 500_000_000)
        pipelineStage = .transcribing
        try? await Task.sleep(nanoseconds: 600_000_000)
        pipelineStage = .analyzing
        try? await Task.sleep(nanoseconds: 400_000_000)
        pipelineStage = .ready
    }
}

