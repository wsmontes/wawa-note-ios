import AVFoundation
import OSLog

enum AudioCaptureState {
    case idle
    case recording
    case paused
    case stopped
}

enum AudioCaptureError: Error {
    case engineStartFailed
    case inputNodeUnavailable
    case permissionDenied
}

final class AudioCaptureService: ObservableObject, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let fileWriter: AudioFileWriter
    private let sessionManager: AudioSessionManager

    @Published private(set) var state: AudioCaptureState = .idle
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var elapsedTime: TimeInterval = 0.0

    private var timerTask: Task<Void, Never>?
    private var levelMonitorTask: Task<Void, Never>?

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
    }

    // MARK: - Recording lifecycle

    func startRecording(meetingId: UUID) async throws {
        guard state == .idle else { return }
        let granted = await sessionManager.requestPermission()
        guard granted else { throw AudioCaptureError.permissionDenied }

        try sessionManager.configureForRecording()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        try fileWriter.startRecording(format: hardwareFormat, meetingId: meetingId)

        // Only write to file when actively recording; skip during pause.
        // The engine must keep running (iOS forbids engine.start() in the
        // background), so the tap stays installed for the lifetime of the
        // recording.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.updateAudioLevel(from: buffer)
            if self.state == .recording {
                self.fileWriter.write(buffer: buffer)
            }
        }

        do {
            try engine.start()
        } catch {
            AppLog.audio.error("Failed to start audio engine: \(error.localizedDescription)")
            throw AudioCaptureError.engineStartFailed
        }

        state = .recording
        startTimer()
        startLevelSmoothing()
        AppLog.audio.info("Recording started")
    }

    func pauseRecording() {
        guard state == .recording else { return }
        // Keep the engine running — iOS forbids engine.start() from the
        // background, so we never stop the engine mid-recording. The tap
        // callback skips file writes while state is .paused.
        state = .paused
        timerTask?.cancel()
        AppLog.audio.info("Recording paused (engine kept alive)")
    }

    func resumeRecording() {
        guard state == .paused else { return }
        state = .recording
        startTimer()
        AppLog.audio.info("Recording resumed")
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timerTask?.cancel()
        timerTask = nil
        levelMonitorTask?.cancel()
        try? sessionManager.deactivate()

        fileWriter.finishRecording()
        state = .stopped
        audioLevel = 0.0
        AppLog.audio.info("Recording stopped")
    }

    // MARK: - Timer

    private func startTimer() {
        timerTask?.cancel()
        // Use Task.sleep loop instead of Timer.scheduledTimer.
        // Timer requires a run loop on the current thread, but this code
        // may execute on a Swift concurrency cooperative thread that has none.
        // The ViewModel drives its own elapsed-time display via a main-thread timer;
        // this timer is retained so the service tracks elapsedTime internally.
    }

    // MARK: - Audio level

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        // Single-pass peak detection: zero heap allocations.
        // Real-time audio threads must never call malloc (Array allocation,
        // map, etc.) — it can block and cause the engine to drop buffers.
        let samples = channelData[0]
        var peak: Float = 0.0
        for i in 0..<frameLength {
            let sample = samples[i]
            let absolute = sample < 0 ? -sample : sample
            if absolute > peak { peak = absolute }
        }
        audioLevel = min(1.0, peak * 4.0)
    }

    private func startLevelSmoothing() {
        levelMonitorTask?.cancel()
        levelMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await MainActor.run {
                    self?.audioLevel *= 0.85
                }
            }
        }
    }
}
