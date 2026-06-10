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

        // Use the hardware format directly. AAC encoder needs a matching bitrate
        // for the sample rate. Built-in mic: 44.1kHz/96kbps. AirPods HFP: 8kHz/24kbps.
        // This avoids any manual upsampling that could introduce artifacts.
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

        do {
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            currentFileURL = fileURL
            currentMeetingId = meetingId
            AppLog.audio.info("Audio file created: \(fileURL.lastPathComponent) \(sampleRate)Hz AAC \(bitRate)bps meeting=\(meetingId.uuidString.prefix(8))")
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
        let hadErrors = hasWriteErrors
        let errorCount = writeErrorCount
        let finalSize = fileSize
        // Explicitly nil out the file reference to flush and close.
        // AVAudioFile deinit triggers final AAC frame flush and closes the fd.
        audioFile = nil
        currentMeetingId = nil
        if hadErrors {
            AppLog.warn("audio", "Audio file writer finished with \(errorCount) write error(s) — file may be incomplete. size=\(finalSize) bytes")
        } else {
            AppLog.event("audio", "Audio file writer finished cleanly — size=\(finalSize) bytes")
        }
    }

    func cleanupAbandonedRecording(for meetingId: UUID) {
        guard currentMeetingId == nil else { return }
        // Remove any partially-written file for this meeting
        try? fileStore.deleteMeetingDirectory(for: meetingId)
    }
}
