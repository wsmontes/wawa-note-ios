import Foundation

enum FileArtifactStoreError: Error {
    case fileNotFound
    case writeFailed
    case readFailed
    case encodingFailed
}

enum AppFileConstants {
    static let audioFileName = "audio.m4a"
    static let transcriptFileName = "transcript.json"
    static let analysisFileName = "analysis.json"
    static let dynamicAnalysisFileName = "analysis.dynamic.json"
    static let partialTranscriptFileName = "transcript_partial.json"
    static let checkpointFileName = "checkpoint.json"
    static let embeddingFileName = "embedding.json"
    static let scanFileName = "scan"
    static let scanFilePattern = "scan_%d.jpg"
}

final class FileArtifactStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.baseURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    // MARK: - Directory management

    func meetingDirectoryURL(for meetingId: UUID) -> URL {
        itemDirectoryURL(for: meetingId)
    }

    // MARK: - New knowledge workspace paths

    func itemDirectoryURL(for itemId: UUID) -> URL {
        baseURL.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(itemId.uuidString, isDirectory: true)
    }

    func mediaURL(for contentHash: String, ext: String) -> URL {
        baseURL.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("\(contentHash).\(ext)")
    }

    func configsDirectoryURL() -> URL {
        baseURL.appendingPathComponent("configs", isDirectory: true)
    }

    func chatDirectoryURL() -> URL {
        baseURL.appendingPathComponent("Chat", isDirectory: true)
    }

    func createMeetingDirectory(for meetingId: UUID) throws {
        let url = meetingDirectoryURL(for: meetingId)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func deleteMeetingDirectory(for meetingId: UUID) throws {
        let url = meetingDirectoryURL(for: meetingId)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: - Audio

    func audioFileURL(for meetingId: UUID) -> URL {
        meetingDirectoryURL(for: meetingId)
            .appendingPathComponent("audio.m4a")
    }

    func audioFileExists(for meetingId: UUID) -> Bool {
        fileManager.fileExists(atPath: audioFileURL(for: meetingId).path)
    }

    func copyAudioToMeeting(sourceURL: URL, meetingId: UUID) throws {
        try createMeetingDirectory(for: meetingId)
        let destURL = audioFileURL(for: meetingId)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)
    }

    func deleteAudio(for meetingId: UUID) throws {
        let url = audioFileURL(for: meetingId)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: - Artifacts

    func writeArtifact<T: Encodable>(_ value: T, fileName: String, meetingId: UUID) throws {
        let url = meetingDirectoryURL(for: meetingId).appendingPathComponent(fileName)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch is EncodingError {
            throw FileArtifactStoreError.encodingFailed
        } catch {
            throw FileArtifactStoreError.writeFailed
        }
    }

    func readArtifact<T: Decodable>(_ type: T.Type, fileName: String, meetingId: UUID) throws -> T {
        let url = meetingDirectoryURL(for: meetingId).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileArtifactStoreError.fileNotFound
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch is DecodingError {
            throw FileArtifactStoreError.readFailed
        } catch {
            throw FileArtifactStoreError.readFailed
        }
    }

    func artifactExists(fileName: String, meetingId: UUID) -> Bool {
        let url = meetingDirectoryURL(for: meetingId).appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Partial transcript (checkpointing)

    private func partialTranscriptURL(for meetingId: UUID) -> URL {
        meetingDirectoryURL(for: meetingId).appendingPathComponent("transcript_partial.json")
    }

    private func partialCheckpointURL(for meetingId: UUID) -> URL {
        meetingDirectoryURL(for: meetingId).appendingPathComponent("checkpoint.json")
    }

    func writePartialTranscript(_ transcript: Transcript, checkpoint: TranscriptionCheckpoint, meetingId: UUID) throws {
        try createMeetingDirectory(for: meetingId)

        let tURL = partialTranscriptURL(for: meetingId)
        let tData = try JSONEncoder().encode(transcript)
        try tData.write(to: tURL, options: .atomic)

        let cURL = partialCheckpointURL(for: meetingId)
        let cData = try JSONEncoder().encode(checkpoint)
        try cData.write(to: cURL, options: .atomic)
    }

    func readPartialCheckpoint(meetingId: UUID) throws -> TranscriptionCheckpoint? {
        let url = partialCheckpointURL(for: meetingId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)
    }

    func readPartialTranscript(meetingId: UUID) throws -> Transcript? {
        let url = partialTranscriptURL(for: meetingId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Transcript.self, from: data)
    }

    func commitPartialTranscript(meetingId: UUID) throws {
        let partialURL = partialTranscriptURL(for: meetingId)
        let finalURL = meetingDirectoryURL(for: meetingId).appendingPathComponent("transcript.json")
        guard fileManager.fileExists(atPath: partialURL.path) else { return }
        try? fileManager.removeItem(at: finalURL)
        try fileManager.moveItem(at: partialURL, to: finalURL)
        try? fileManager.removeItem(at: partialCheckpointURL(for: meetingId))
    }

    func deletePartialTranscript(meetingId: UUID) {
        try? fileManager.removeItem(at: partialTranscriptURL(for: meetingId))
        try? fileManager.removeItem(at: partialCheckpointURL(for: meetingId))
    }

    // MARK: - Export

    func exportsDirectoryURL(for meetingId: UUID) -> URL {
        meetingDirectoryURL(for: meetingId)
            .appendingPathComponent("exports", isDirectory: true)
    }

    func createExportsDirectory(for meetingId: UUID) throws {
        let url = exportsDirectoryURL(for: meetingId)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
