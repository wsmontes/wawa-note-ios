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

    func startRecording(format: AVAudioFormat, meetingId: UUID) throws {
        try fileStore.createMeetingDirectory(for: meetingId)

        let fileURL = fileStore.audioFileURL(for: meetingId)

        // Always use 44.1kHz for AAC encoding — the encoder rejects sample rates
        // below ~16kHz when combined with 128kbps bitrate (AirPods HFP = 8kHz).
        // AVAudioFile.write() converts automatically from the hardware format,
        // so the tap can deliver any sample rate and the file gets it right.
        let outputRate: Double = 44100

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96000
        ]

        do {
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            currentFileURL = fileURL
            currentMeetingId = meetingId
            AppLog.audio.info("Audio file created: \(fileURL.lastPathComponent) output=\(outputRate)Hz hardware=\(format.sampleRate)Hz meeting=\(meetingId.uuidString.prefix(8))")
        } catch {
            AppLog.error("audio", "Failed to create audio file: \(error.localizedDescription)")
            throw AudioFileWriterError.fileCreationFailed
        }
    }

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
                    let nsError = error as NSError
                    AppLog.error("audio", "Failed to write audio buffer after 3 retries (#\(writeErrorCount)): \(error.localizedDescription)")
                    return
                }
                Thread.sleep(forTimeInterval: [0.1, 0.2, 0.4][attempt])
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
