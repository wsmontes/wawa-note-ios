import AVFoundation
import OSLog

enum AudioFileWriterError: Error {
    case fileCreationFailed
    case writeFailed
    case diskFull
}

/// Metadata about a closed segment, returned when closing.
struct ClosedSegmentInfo: Sendable {
    let index: Int
    let fileName: String
    let endedAt: Date
    let fileSize: Int64
}

/// Thread-safe audio file writer. All operations (write, close, open, finish)
/// are serialized through a single internal queue. This prevents races between
/// the audio tap's write callbacks and lifecycle operations (route change, stop).
final class AudioFileWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileStore: FileArtifactStore
    private let queue = DispatchQueue(label: "com.wawa-note.audio.filewriter", qos: .userInitiated)

    // All access must go through `queue.sync` or `queue.async`
    private var _audioFile: AVAudioFile?
    private var _currentFileURL: URL?
    private var _currentMeetingId: UUID?
    private var _segmentIndex: Int = 0
    private var _writeErrorCount: Int = 0
    private var _lastWriteError: Error?

    var currentFileURL: URL? { queue.sync { _currentFileURL } }
    var segmentIndex: Int { queue.sync { _segmentIndex } }
    var hasWriteErrors: Bool { queue.sync { _writeErrorCount > 0 } }
    var fileSize: Int64 { queue.sync { _fileSize } }
    var activeFile: AVAudioFile? { queue.sync { _audioFile } }
    private var _fileSize: Int64 {
        guard let url = _currentFileURL else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    init(fileManager: FileManager = .default, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileManager = fileManager
        self.fileStore = fileStore
    }

    // MARK: - Public API (all serialized through queue)

    func startRecording(format: AVAudioFormat, meetingId: UUID) throws {
        try queue.sync {
            _segmentIndex = 0
            try fileStore.createMeetingDirectory(for: meetingId)
            _currentMeetingId = meetingId
            try _openSegment(meetingId: meetingId, format: format)
        }
    }

    @discardableResult
    func closeCurrentSegment() -> ClosedSegmentInfo? {
        queue.sync { _closeCurrentSegment() }
    }

    func startNewSegment(meetingId: UUID, format: AVAudioFormat) throws {
        try queue.sync {
            _closeCurrentSegment()
            _segmentIndex += 1
            try _openSegment(meetingId: meetingId, format: format)
        }
    }

    func write(buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let file = self._audioFile else { return }
            for attempt in 0...3 {
                do {
                    try file.write(from: buffer)
                    return
                } catch {
                    if attempt == 3 {
                        self._writeErrorCount += 1
                        self._lastWriteError = error
                        AppLog.error("audio", "Write failed #\(self._writeErrorCount): \(error.localizedDescription)")
                        return
                    }
                    Thread.sleep(forTimeInterval: [0.1, 0.2, 0.4][attempt])
                }
            }
        }
    }

    @discardableResult
    func finishRecording() -> ClosedSegmentInfo? {
        queue.sync {
            let info = _closeCurrentSegment()
            _currentMeetingId = nil
            let total = _segmentIndex + 1
            if _writeErrorCount > 0 {
                AppLog.warn("audio", "Writer finished with \(_writeErrorCount) errors — \(total) segments")
            } else {
                AppLog.event("audio", "Writer finished cleanly — \(total) segments")
            }
            return info
        }
    }

    func cleanupAbandonedRecording(for meetingId: UUID) {
        queue.sync {
            guard _currentMeetingId == nil else { return }
            try? fileStore.deleteMeetingDirectory(for: meetingId)
        }
    }

    // MARK: - Private (must be called on `queue`)

    private func _closeCurrentSegment() -> ClosedSegmentInfo? {
        guard _audioFile != nil, let meetingId = _currentMeetingId else { return nil }
        let idx = _segmentIndex
        let fileName = String(format: "segment-%03d.m4a", idx)
        let size = _fileSize
        let endedAt = Date()
        _audioFile = nil
        _currentFileURL = nil
        AppLog.audio.info("Segment \(idx) closed — \(size) bytes")
        return ClosedSegmentInfo(index: idx, fileName: fileName, endedAt: endedAt, fileSize: size)
    }

    private func _openSegment(meetingId: UUID, format: AVAudioFormat) throws {
        let segmentsDir = fileStore.segmentsDirectoryURL(for: meetingId)
        try fileManager.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        let fileName = String(format: "segment-%03d.m4a", _segmentIndex)
        let fileURL = segmentsDir.appendingPathComponent(fileName)

        let sampleRate = format.sampleRate
        let bitRate: Int = sampleRate >= 44100 ? 96000
            : sampleRate >= 22050 ? 64000
            : sampleRate >= 16000 ? 32000
            : 24000

        _audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        _currentFileURL = fileURL
        AppLog.audio.info("Segment \(self._segmentIndex): \(fileName) \(sampleRate)Hz AAC")
    }
}
