import AVFoundation
import OSLog

enum AudioFileWriterError: Error {
    case fileCreationFailed
}

final class AudioFileWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileStore: FileArtifactStore
    private var audioFile: AVAudioFile?
    private(set) var currentFileURL: URL?
    private var currentMeetingId: UUID?

    init(fileManager: FileManager = .default, fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileManager = fileManager
        self.fileStore = fileStore
    }

    var isWriting: Bool { audioFile != nil }

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
            AppLog.audio.error("Failed to create audio file: \(error.localizedDescription)")
            throw AudioFileWriterError.fileCreationFailed
        }
    }

    func write(buffer: AVAudioPCMBuffer) {
        guard let file = audioFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            AppLog.audio.error("Failed to write audio buffer: \(error.localizedDescription)")
        }
    }

    func finishRecording() {
        audioFile = nil
        currentMeetingId = nil
        AppLog.audio.info("Audio file writer finished")
    }
}
