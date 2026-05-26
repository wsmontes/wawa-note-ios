import Foundation

enum FileArtifactStoreError: Error {
    case fileNotFound
    case writeFailed
    case readFailed
    case encodingFailed
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
        baseURL.appendingPathComponent(meetingId.uuidString, isDirectory: true)
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
