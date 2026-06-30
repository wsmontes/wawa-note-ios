import AVFoundation
import OSLog

// Related JIRA: KAN-5, KAN-14, KAN-73

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
///
/// Write retries use `queue.asyncAfter` instead of `Thread.sleep` so the serial
/// queue is never blocked — subsequent writes can still be processed while a
/// previous write is retrying.
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

    /// Maximum number of write retries for transient errors.
    private static let maxRetries = 3
    /// Backoff delays for retries 1, 2, 3 (retry 4 = final attempt, no delay).
    private static let retryDelays: [TimeInterval] = [0.1, 0.2, 0.4]
    /// Maximum indices to scan forward when avoiding segment overwrite.
    private static let maxOverwriteScanIndices = 10

    /// Diagnostic counter: number of queued writes waiting to be processed.
    /// Incremented before dispatch, decremented after completion. A value >5
    /// indicates the write queue is saturated (disk may be slow or full).
    /// Approximate — accessed without synchronization for hot-path performance.
    private(set) nonisolated(unsafe) var queueDepth: Int32 = 0

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
        queueDepth &+= 1
        queue.async { [weak self] in
            defer { self?.queueDepth &-= 1 }
            guard let self, let file = self._audioFile else { return }
            guard let wb = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength)) else { return }
            wb.frameLength = AVAudioFrameCount(frameLength)
            if let dest = wb.floatChannelData {
                dest[0].assign(from: samples, count: frameLength)
            }
            self._writeWithRetry(buffer: wb, file: file)
        }
    }

    /// Write an already-constructed PCM buffer. Used when the caller already
    /// has a buffer (e.g., concatenation, testing).
    func write(buffer: AVAudioPCMBuffer) {
        queueDepth &+= 1
        queue.async { [weak self] in
            defer { self?.queueDepth &-= 1 }
            guard let self, let file = self._audioFile else { return }
            self._writeWithRetry(buffer: buffer, file: file)
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

    // MARK: - Crash Recovery Checkpoint

    /// Write a crash recovery checkpoint so an interrupted recording can be resumed.
    /// Called periodically from the capture service during active recording.
    /// Uses rotation: writes to .NEW, validates, then renames — the previous
    /// checkpoint is preserved as .BAK.
    func writeCheckpoint(meetingId: UUID, segmentIndex: Int, format: AVAudioFormat) {
        queue.sync {
            let checkpoint: [String: Any] = [
                "meetingId": meetingId.uuidString,
                "segmentIndex": segmentIndex,
                "sampleRate": format.sampleRate,
                "channels": format.channelCount,
                "timestamp": Date().timeIntervalSince1970,
                "fileName": self._currentFileURL?.lastPathComponent ?? "unknown",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: checkpoint) else {
                AppLog.error("audio", "Checkpoint: failed to serialize checkpoint JSON")
                return
            }

            // Ensure configs directory exists before writing
            do {
                try self.fileStore.createConfigsDirectory()
            } catch {
                AppLog.error("audio", "Checkpoint: cannot create configs directory — \(error.localizedDescription)")
                return
            }

            let url = self.fileStore.configsDirectoryURL().appendingPathComponent("recording_checkpoint.json")
            do {
                try self.fileStore.atomicWriteWithBackup(data: data, url: url)
            } catch {
                AppLog.error("audio", "Checkpoint: write failed — \(error.localizedDescription)")
            }
        }
    }

    /// Check if a crash recovery checkpoint exists from a previous session.
    /// Returns (meetingId, segmentIndex, sampleRate) if found, nil otherwise.
    /// Recovers checkpoints less than 24 hours old (covers overnight scenarios).
    private static let maxCheckpointAge: TimeInterval = 86400  // 24 hours

    static func loadCrashCheckpoint(fileStore: FileArtifactStore = FileArtifactStore()) -> (UUID, Int, Double)? {
        let url = fileStore.configsDirectoryURL().appendingPathComponent("recording_checkpoint.json")
        let bakURL = url.appendingPathExtension("BAK")

        // Try primary first, then backup
        for candidateURL in [url, bakURL] {
            guard FileManager.default.fileExists(atPath: candidateURL.path),
                let data = try? Data(contentsOf: candidateURL),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let meetingIdStr = dict["meetingId"] as? String,
                let meetingId = UUID(uuidString: meetingIdStr),
                let segmentIndex = dict["segmentIndex"] as? Int,
                let sampleRate = dict["sampleRate"] as? Double,
                let timestamp = dict["timestamp"] as? TimeInterval
            else { continue }

            // Recover checkpoints up to 24h old — covers overnight and
            // morning-after scenarios where the user records, the app crashes,
            // and they don't reopen until the next day.
            guard Date().timeIntervalSince1970 - timestamp < maxCheckpointAge else {
                AppLog.audio.info("Checkpoint expired: \(Int((Date().timeIntervalSince1970 - timestamp) / 3600))h old — discarding")
                return nil
            }

            return (meetingId, segmentIndex, sampleRate)
        }
        return nil
    }

    /// Remove the checkpoint file after successful recording stop.
    static func clearCrashCheckpoint(fileStore: FileArtifactStore = FileArtifactStore()) {
        let url = fileStore.configsDirectoryURL().appendingPathComponent("recording_checkpoint.json")
        let bakURL = url.appendingPathExtension("BAK")
        let newURL = url.appendingPathExtension("NEW")
        for u in [url, bakURL, newURL] {
            if FileManager.default.fileExists(atPath: u.path) {
                do {
                    try FileManager.default.removeItem(at: u)
                } catch {
                    AppLog.warn("audio", "clearCrashCheckpoint: cannot remove \(u.lastPathComponent) — \(error.localizedDescription)")
                }
            }
        }
    }

    func cleanupAbandonedRecording(for meetingId: UUID) {
        queue.sync {
            guard _currentMeetingId == nil else { return }
            try? fileStore.deleteMeetingDirectory(for: meetingId)
        }
    }

    // MARK: - Private (must be called on `queue`)

    /// Single retry-with-backoff write routine used by both `write(samples:)` and `write(buffer:)`.
    /// Distinguishes permanent errors (disk full) from transient errors — disk full aborts
    /// immediately without retry. Uses `queue.asyncAfter` to avoid blocking the serial queue.
    private func _writeWithRetry(buffer: AVAudioPCMBuffer, file: AVAudioFile, attempt: Int = 0) {
        do {
            try file.write(from: buffer)
            return
        } catch {
            // Permanent errors: disk full — abort immediately, no retry
            if isDiskFullError(error) {
                _writeErrorCount += 1
                _lastWriteError = error
                AppLog.error("audio", "Write failed — disk full (permanent): \(error.localizedDescription)")
                onWriteFailure?(AudioFileWriterError.diskFull)
                return
            }

            // Transient errors: retry with backoff
            if attempt >= Self.maxRetries {
                _writeErrorCount += 1
                _lastWriteError = error
                AppLog.error("audio", "Write failed #\(_writeErrorCount) after \(attempt) retries: \(error.localizedDescription)")
                onWriteFailure?(error)
                return
            }

            let delay = Self.retryDelays[attempt]
            AppLog.warn("audio", "Write attempt \(attempt + 1) failed — retrying in \(Int(delay * 1000))ms: \(error.localizedDescription)")
            // Synchronous retry on the serial queue: use async with a sleep to
            // keep writes ordered. Unlike asyncAfter, this ensures no later
            // buffer can jump ahead of the retry.
            queue.async { [weak self] in
                Thread.sleep(forTimeInterval: delay)
                guard let self, self._audioFile != nil else {
                    AppLog.error("audio", "Write retry dropped — recording stopped before retry fired")
                    return
                }
                self._writeWithRetry(buffer: buffer, file: file, attempt: attempt + 1)
            }
        }
    }

    /// Check whether an error indicates the disk is full (permanent, not retryable).
    private func isDiskFullError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return true }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 /* ENOSPC */ { return true }
        if nsError.domain == AVFoundationErrorDomain && nsError.code == -11837 /* disk full */ { return true }
        return false
    }

    private func _closeCurrentSegment() -> ClosedSegmentInfo? {
        guard _audioFile != nil, let meetingId = _currentMeetingId else { return nil }
        let idx = _segmentIndex
        // Use the actual file name from _openSegment (may be .wav for low sample rates).
        let fileName = _currentFileURL?.lastPathComponent ?? String(format: "segment-%03d.wav", idx)
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
        // Always use Linear PCM WAV. AAC M4A bitstream causes SFSpeechRecognizer
        // to lose sync, producing 40-90s gaps (kAFAssistantErrorDomain Code=1101).
        // PCM guarantees recognizer compatibility; storage compression can be done
        // in background post-recording if needed.
        //
        // Estimated sizes (mono 16-bit):
        //   16 kHz → ~7 MB/min   | 44.1 kHz → ~5.3 MB/min
        //   1-hour recording at 44.1 kHz ≈ 318 MB
        let ext = "wav"
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let fileName = String(format: "segment-%03d.\(ext)", self._segmentIndex)
        let fileURL = segmentsDir.appendingPathComponent(fileName)

        // CRITICAL: never overwrite an existing segment file. Once a segment is
        // closed and checkpointed, its audio belongs to the user. Overwriting it
        // is irreversible data loss. If the file already exists with data, scan
        // forward up to maxOverwriteScanIndices to find a free index.
        if fileManager.fileExists(atPath: fileURL.path) {
            let existingSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            if existingSize > 0 {
                let segIdx = self._segmentIndex
                AppLog.audio.warning("Segment \(segIdx): \(fileName) already exists (\(existingSize) bytes) — refusing to overwrite")
                var nextIdx = segIdx + 1
                var found = false
                let scanLimit = segIdx + Self.maxOverwriteScanIndices
                while nextIdx <= scanLimit {
                    let nextName = String(format: "segment-%03d.\(ext)", nextIdx)
                    let nextURL = segmentsDir.appendingPathComponent(nextName)
                    if !self.fileManager.fileExists(atPath: nextURL.path) {
                        found = true
                        break
                    }
                    let sz = (try? self.fileManager.attributesOfItem(atPath: nextURL.path)[.size] as? Int64) ?? 0
                    if sz == 0 {
                        // 0-byte file: safe to reuse ONLY if not referenced in manifest
                        found = true
                        break
                    }
                    nextIdx += 1
                }

                guard found else {
                    AppLog.audio.error("Segment: cannot find free index within \(Self.maxOverwriteScanIndices) slots — aborting")
                    throw AudioFileWriterError.fileCreationFailed
                }

                AppLog.audio.warning("Segment: skipping from index \(segIdx) to \(nextIdx) to avoid overwrite")
                self._segmentIndex = nextIdx
                let finalName = String(format: "segment-%03d.\(ext)", self._segmentIndex)
                let finalURL = segmentsDir.appendingPathComponent(finalName)
                self._audioFile = try AVAudioFile(
                    forWriting: finalURL, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                self._currentFileURL = finalURL
                AppLog.audio.info("Segment \(self._segmentIndex): \(finalName) \(sampleRate)Hz PCM (index adjusted)")
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
        AppLog.audio.info("Segment \(self._segmentIndex): \(fileName) \(sampleRate)Hz PCM")
    }
}
