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

    /// Access to the underlying audio file for creating write buffers.
    var activeFile: AVAudioFile? { audioFile }

    init(fileManager: FileManager = .default, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileManager = fileManager
        self.fileStore = fileStore
    }

    var isWriting: Bool { audioFile != nil }

    var hasWriteErrors: Bool { writeErrorCount > 0 }

    /// Whether the recording file is likely corrupted (had write errors).
    var isFileCorrupted: Bool { writeErrorCount > 0 }

    var fileSize: Int64 {
        guard let url = currentFileURL else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    func startRecording(format: AVAudioFormat, meetingId: UUID) throws {
        try fileStore.createMeetingDirectory(for: meetingId)

        let fileURL = fileStore.audioFileURL(for: meetingId)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            currentFileURL = fileURL
            currentMeetingId = meetingId
            AppLog.audio.info("Audio file created: \(fileURL.lastPathComponent) at \(format.sampleRate)Hz for meeting \(meetingId.uuidString.prefix(8))")
        } catch {
            AppLog.error("audio", "Failed to create audio file: \(error.localizedDescription)")
            throw AudioFileWriterError.fileCreationFailed
        }
    }

    func write(buffer: AVAudioPCMBuffer) {
        guard let file = audioFile else { return }
        let maxRetries = 3
        let retryDelays = [0.1, 0.2, 0.4]  // Exponential backoff in seconds

        for attempt in 0...maxRetries {
            do {
                try file.write(from: buffer)
                return  // Success
            } catch {
                if attempt == maxRetries {
                    writeErrorCount += 1
                    lastWriteError = error
                    let nsError = error as NSError
                    AppLog.error("audio", "Failed to write audio buffer after \(maxRetries) retries (#\(writeErrorCount)): \(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code)")
                    return
                }
                let delay = retryDelays[attempt]
                AppLog.warn("audio", "Audio write retry \(attempt + 1)/\(maxRetries) after \(delay)s: \(error.localizedDescription)")
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    func finishRecording() {
        // Force the file to be properly finalized by setting to nil,
        // which triggers AVAudioFile's deinit and closes the fd.
        let hadErrors = hasWriteErrors
        let errorCount = writeErrorCount
        audioFile = nil
        currentMeetingId = nil
        if hadErrors {
            AppLog.warn("audio", "Audio file writer finished with \(errorCount) write error(s) — file may be incomplete")
        } else {
            AppLog.event("audio", "Audio file writer finished cleanly — size=\(fileSize) bytes")
        }
    }

    func cleanupAbandonedRecording(for meetingId: UUID) {
        guard currentMeetingId == nil else { return }
        // Remove any partially-written file for this meeting
        try? fileStore.deleteMeetingDirectory(for: meetingId)
    }
}
