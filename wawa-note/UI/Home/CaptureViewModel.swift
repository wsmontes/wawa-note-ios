import SwiftUI
import Combine
import SwiftData

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var recordingState: RecordingUIState = .idle
    @Published var elapsedTimeFormatted: String = "00:00"
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?
    @Published var savedItemId: UUID?
    @Published var pipelineStage: PipelineStage?

    enum PipelineStage: String {
        case transcribing = "Transcribing..."
        case analyzing = "Analyzing..."
    }

    var modelContext: ModelContext?
    var contentPipeline: ContentPipelineService?
    var processingQueue: ProcessingQueueService?

    private var coordinator: RecordingCoordinator?
    private var cancellables: Set<AnyCancellable> = []

    init() {}

    func bind(coordinator: RecordingCoordinator) {
        guard self.coordinator == nil else { return }
        self.coordinator = coordinator

        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recordingState = $0 }
            .store(in: &cancellables)

        coordinator.$elapsedTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.elapsedTimeFormatted = coordinator.elapsedTimeFormatted }
            .store(in: &cancellables)

        coordinator.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.audioLevel = $0 }
            .store(in: &cancellables)

        coordinator.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.errorMessage = $0 }
            .store(in: &cancellables)

        coordinator.$savedItemId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.savedItemId = $0 }
            .store(in: &cancellables)

        recordingState = coordinator.state
        elapsedTimeFormatted = coordinator.elapsedTimeFormatted
        audioLevel = coordinator.audioLevel
        savedItemId = coordinator.savedItemId
    }

    func startRecording(title: String? = nil, projectID: UUID? = nil) {
        pipelineStage = nil
        coordinator?.startRecording(title: title, projectID: projectID)
    }

    func pauseRecording() { coordinator?.pauseRecording() }
    func resumeRecording() { coordinator?.resumeRecording() }

    func stopRecording() {
        coordinator?.stopRecording()
        launchPipeline()
    }

    func finishCapture() {
        pipelineStage = nil
        savedItemId = nil
        errorMessage = nil
        coordinator?.returnToIdle()
    }

    // MARK: - Pipeline

    private func launchPipeline() {
        guard let itemId = savedItemId ?? coordinator?.savedItemId else { return }
        _ = processingQueue?.enqueue(itemID: itemId, trigger: .newCapture)
    }
}
