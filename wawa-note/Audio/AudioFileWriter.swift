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

    /// Called on the writer's queue when a write fails after all retries.
    /// The capture service should close the current segment and alert the user.
    var onWriteFailure: ((_ error: Error) -> Void)?

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

    /// Start a brand-new logical recording. Resets segment index to 0 and creates
    /// the meeting directory. MUST only be called once per KnowledgeItem.
    /// NEVER call this during route switching — use rotateToNewSegment instead.
    func startRecording(format: AVAudioFormat, meetingId: UUID) throws {
        try queue.sync {
            _segmentIndex = 0
            _writeErrorCount = 0
            _lastWriteError = nil
            try fileStore.createMeetingDirectory(for: meetingId)
            _currentMeetingId = meetingId
            try _openSegment(meetingId: meetingId, format: format)
        }
    }

    @discardableResult
    func closeCurrentSegment() -> ClosedSegmentInfo? {
        queue.sync { _closeCurrentSegment() }
    }

    /// Atomically close the current segment and open a new one.
    /// Returns the closed segment's metadata so the caller can finalize the manifest.
    @discardableResult
    func rotateToNewSegment(meetingId: UUID, format: AVAudioFormat) throws -> ClosedSegmentInfo? {
        try queue.sync {
            let closed = _closeCurrentSegment()
            _segmentIndex += 1
            try _openSegment(meetingId: meetingId, format: format)
            return closed
        }
    }

    /// Open a new segment without closing the current one.
    /// Callers MUST ensure the current segment is already closed (via closeCurrentSegment()
    /// or rotateToNewSegment()) before calling this. Increments the segment index.
    func startNewSegment(meetingId: UUID, format: AVAudioFormat) throws {
        try queue.sync {
            _segmentIndex += 1
            try _openSegment(meetingId: meetingId, format: format)
        }
    }

    /// Open the next segment for an existing recording, using the manifest as the
    /// source of truth for the next segment index. NEVER resets the index to 0.
    /// Callers MUST ensure the current segment is already closed.
    ///
    /// - Parameters:
    ///   - meetingId: The existing recording's item ID.
    ///   - format: Audio format for the new segment.
    ///   - manifestNextIndex: The next available index from the manifest
    ///     (`(manifest.segments.map(\.index).max() ?? -1) + 1`).
    func startNextSegmentForExistingRecording(
        meetingId: UUID,
        format: AVAudioFormat,
        manifestNextIndex: Int
    ) throws {
        try queue.sync {
            // Safety: never allow the writer index to go backward. If the manifest
            // says index N but the writer is at M > N, trust the writer (it owns the
            // actual file state). If the writer is behind, sync to the manifest.
            if manifestNextIndex > _segmentIndex {
                _segmentIndex = manifestNextIndex
            }
            try _openSegment(meetingId: meetingId, format: format)
        }
    }

    /// Write raw float samples. Creates the PCM buffer on the writer's queue
    /// and appends to the current file. This is the single serialization point
    /// for all audio data — callers do NOT need their own write queue.
    func write(samples: [Float], frameLength: Int, format: AVAudioFormat) {
        queue.async { [weak self] in
            guard let self, let file = self._audioFile else { return }
            guard let wb = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength)) else { return }
            wb.frameLength = AVAudioFrameCount(frameLength)
            if let dest = wb.floatChannelData {
                dest[0].initialize(from: samples, count: frameLength)
            }
            for attempt in 0...3 {
                do {
                    try file.write(from: wb)
                    return
                } catch {
                    if attempt == 3 {
                        self._writeErrorCount += 1
                        self._lastWriteError = error
                        AppLog.error("audio", "Write failed #\(self._writeErrorCount): \(error.localizedDescription)")
                        self.onWriteFailure?(error)
                        return
                    }
                    Thread.sleep(forTimeInterval: [0.1, 0.2, 0.4][attempt])
                }
            }
        }
    }

    /// Write an already-constructed PCM buffer. Used when the caller already
    /// has a buffer (e.g., concatenation, testing).
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
                        self.onWriteFailure?(error)
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
        // Use the actual file name from _openSegment (may be .wav for low sample rates).
        let fileName = _currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.m4a", idx)
        let size = _fileSize
        let endedAt = Date()
        _audioFile = nil
        _currentFileURL = nil
        AppLog.audio.info("Segment \(idx) closed — \(fileName) \(size) bytes")
        return ClosedSegmentInfo(index: idx, fileName: fileName, endedAt: endedAt, fileSize: size)
    }

    private func _openSegment(meetingId: UUID, format: AVAudioFormat) throws {
        let segmentsDir = fileStore.segmentsDirectoryURL(for: meetingId)
        try fileManager.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        let sampleRate = format.sampleRate
        // AAC encoder rejects sample rates below ~16kHz on iOS (kAudioFormatUnsupportedDataFormatError).
        // Use Linear PCM WAV for low rates (Bluetooth HFP at 8kHz), AAC for standard rates.
        let usePCM = sampleRate < 16000
        let ext = usePCM ? "wav" : "m4a"

        // Build settings FIRST so we can use them in the overwrite guard below.
        let settings: [String: Any]
        if usePCM {
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        } else {
            let bitRate: Int = sampleRate >= 44100 ? 96000
                : sampleRate >= 32000 ? 64000
                : sampleRate >= 22050 ? 48000
                : 24000
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate
            ]
        }

        let fileName = String(format: "segment-%03d.\(ext)", self._segmentIndex)
        let fileURL = segmentsDir.appendingPathComponent(fileName)

        // CRITICAL: never overwrite an existing segment file. Once a segment is
        // closed and checkpointed, its audio belongs to the user. Overwriting it
        // is irreversible data loss. If the file already exists, scan forward
        // until we find a free index.
        if fileManager.fileExists(atPath: fileURL.path) {
            let existingSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            if existingSize > 0 {
                let segIdx = self._segmentIndex
                AppLog.audio.warning("Segment \(segIdx): \(fileName) already exists (\(existingSize) bytes) — refusing to overwrite")
                var nextIdx = segIdx + 1
                var nextURL: URL
                var nextName: String
                repeat {
                    nextName = String(format: "segment-%03d.\(ext)", nextIdx)
                    nextURL = segmentsDir.appendingPathComponent(nextName)
                    if !self.fileManager.fileExists(atPath: nextURL.path) { break }
                    let sz = (try? self.fileManager.attributesOfItem(atPath: nextURL.path)[.size] as? Int64) ?? 0
                    if sz == 0 { break }
                    nextIdx += 1
                } while nextIdx < segIdx + 1000
                AppLog.audio.warning("Segment: skipping from index \(segIdx) to \(nextIdx) to avoid overwrite")
                self._segmentIndex = nextIdx
                let finalName = String(format: "segment-%03d.\(ext)", self._segmentIndex)
                let finalURL = segmentsDir.appendingPathComponent(finalName)
                self._audioFile = try AVAudioFile(forWriting: finalURL, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                self._currentFileURL = finalURL
                AppLog.audio.info("Segment \(self._segmentIndex): \(finalName) \(sampleRate)Hz \(usePCM ? "PCM" : "AAC") (index adjusted)")
                return
            }
            AppLog.audio.info("Segment \(self._segmentIndex): \(fileName) exists but is 0 bytes — safe to reuse")
        }
        self._audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self._currentFileURL = fileURL
        AppLog.audio.info("Segment \(self._segmentIndex): \(fileName) \(sampleRate)Hz \(usePCM ? "PCM" : "AAC")")
    }
}
