import AVFoundation
import OSLog

enum AudioFileWriterError: Error {
    case fileCreationFailed
    case writeFailed
    case diskFull
}

final class AudioFileWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileStore: FileArtifactStore
    private var audioFile: AVAudioFile?
    private(set) var currentFileURL: URL?
    private var currentMeetingId: UUID?
    private(set) var writeErrorCount: Int = 0
    private(set) var lastWriteError: Error?
    var activeFile: AVAudioFile? { audioFile }

    /// Current segment index (incremented on route changes).
    private(set) var segmentIndex: Int = 0
    private var lastFormat: AVAudioFormat?

    init(fileManager: FileManager = .default, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileManager = fileManager
        self.fileStore = fileStore
    }

    var isWriting: Bool { audioFile != nil }
    var hasWriteErrors: Bool { writeErrorCount > 0 }

    var fileSize: Int64 {
        guard let url = currentFileURL else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Segment lifecycle

    func startRecording(format: AVAudioFormat, meetingId: UUID) throws {
        lastFormat = format
        segmentIndex = 0
        try fileStore.createMeetingDirectory(for: meetingId)
        currentMeetingId = meetingId
        try openSegment(meetingId: meetingId)
    }

    /// Close current segment and open a new one (route change, interruption recovery).
    func startNewSegment(meetingId: UUID) throws {
        closeCurrentSegment()
        segmentIndex += 1
        try openSegment(meetingId: meetingId)
    }

    private func openSegment(meetingId: UUID) throws {
        guard let format = lastFormat else { throw AudioFileWriterError.fileCreationFailed }

        let fileName = String(format: "segment-%03d.m4a", segmentIndex)
        let dir = fileStore.itemDirectoryURL(for: meetingId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(fileName)

        let sampleRate = format.sampleRate
        let bitRate: Int = sampleRate >= 44100 ? 96000
            : sampleRate >= 22050 ? 64000
            : sampleRate >= 16000 ? 32000
            : 24000

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate
        ]

        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        currentFileURL = fileURL
        AppLog.audio.info("Segment \(self.segmentIndex): \(fileName) \(sampleRate)Hz AAC")
    }

    func closeCurrentSegment() {
        guard audioFile != nil else { return }
        let size = fileSize
        audioFile = nil
        AppLog.audio.info("Segment \(self.segmentIndex) closed — \(size) bytes")
    }

    // MARK: - Write

    func write(buffer: AVAudioPCMBuffer) {
        guard let file = audioFile else { return }
        for attempt in 0...3 {
            do {
                try file.write(from: buffer)
                return
            } catch {
                if attempt == 3 {
                    writeErrorCount += 1
                    lastWriteError = error
                    AppLog.error("audio", "Write failed #\(writeErrorCount): \(error.localizedDescription)")
                    return
                }
                Thread.sleep(forTimeInterval: [0.1, 0.2, 0.4][attempt])
            }
        }
    }

    // MARK: - Finish

    func finishRecording() {
        let hadErrors = hasWriteErrors
        let totalSegments = segmentIndex + 1
        closeCurrentSegment()
        currentMeetingId = nil
        lastFormat = nil
        if hadErrors {
            AppLog.warn("audio", "Writer finished with \(writeErrorCount) errors — \(totalSegments) segments")
        } else {
            AppLog.event("audio", "Writer finished cleanly — \(totalSegments) segments")
        }
    }

    func cleanupAbandonedRecording(for meetingId: UUID) {
        guard currentMeetingId == nil else { return }
        try? fileStore.deleteMeetingDirectory(for: meetingId)
    }
}
