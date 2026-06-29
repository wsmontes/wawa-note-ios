import Combine
import SwiftData
import SwiftUI

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var recordingState: RecordingUIState = .idle
    @Published var elapsedTimeFormatted: String = "00:00"
    @Published var audioLevel: Float = 0
    @Published var isAutoPaused: Bool = false
    @Published var silenceDetected: Bool = false
    @Published var errorMessage: String?
    @Published var savedItemId: UUID?
    @Published var pipelineStage: PipelineStage?
    @Published var currentInputPortName: String = ""
    @Published var currentInputIcon: String = "mic.fill"
    @Published var sampleRateBadge: String = ""

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

        coordinator.$isAutoPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isAutoPaused = $0 }
            .store(in: &cancellables)

        coordinator.$silenceDetected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.silenceDetected = $0 }
            .store(in: &cancellables)

        coordinator.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.errorMessage = $0 }
            .store(in: &cancellables)

        coordinator.$savedItemId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.savedItemId = $0 }
            .store(in: &cancellables)

        coordinator.$currentInputPortName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.currentInputPortName = $0 }
            .store(in: &cancellables)

        coordinator.$currentInputIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.currentInputIcon = $0 }
            .store(in: &cancellables)

        // Sample rate badge updates at observation timer rate (10Hz)
        coordinator.$sampleRateBadge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sampleRateBadge = $0 }
            .store(in: &cancellables)

        recordingState = coordinator.state
        elapsedTimeFormatted = coordinator.elapsedTimeFormatted
        audioLevel = coordinator.audioLevel
        savedItemId = coordinator.savedItemId
        currentInputPortName = coordinator.currentInputPortName
        currentInputIcon = coordinator.currentInputIcon
        sampleRateBadge = coordinator.sampleRateBadge
    }

    func startRecording(title: String? = nil, projectID: UUID? = nil) {
        pipelineStage = nil
        coordinator?.startRecording(title: title, projectID: projectID)
    }

    func pauseRecording() { coordinator?.pauseRecording() }
    func resumeRecording() { coordinator?.resumeRecording() }
    func forceBuiltInMic() { coordinator?.forceBuiltInMicRecovery() }

    func stopRecording() {
        coordinator?.stopRecording()
        // Pipeline is triggered internally by RecordingCoordinator after
        // concatenation and validation complete — no duplicate trigger here.
    }

    func finishCapture() {
        pipelineStage = nil
        savedItemId = nil
        errorMessage = nil
        coordinator?.returnToIdle()
    }

    // MARK: - Pipeline

    private func launchPipeline() {
        guard let itemId = savedItemId ?? coordinator?.savedItemId else {
            errorMessage = "Could not start processing. Try again."
            AppLog.error("pipeline", "launchPipeline: savedItemId is nil — pipeline not started")
            return
        }
        guard let queue = processingQueue else {
            errorMessage = "Processing service unavailable. Restart the app."
            AppLog.error("pipeline", "launchPipeline: processingQueue is nil")
            return
        }
        _ = queue.enqueue(itemID: itemId, trigger: .newCapture)
        AppLog.event("pipeline", "Item enqueued: \(itemId.uuidString.prefix(8))")
    }
}
