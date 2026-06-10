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
    static let manifestFileName = "recording.manifest.json"
    static let segmentsDirectoryName = "segments"
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

    // MARK: - Segmented recording

    func segmentsDirectoryURL(for itemId: UUID) -> URL {
        itemDirectoryURL(for: itemId).appendingPathComponent(AppFileConstants.segmentsDirectoryName)
    }

    func segmentURL(for itemId: UUID, fileName: String) -> URL {
        segmentsDirectoryURL(for: itemId).appendingPathComponent(fileName)
    }

    func recordingManifestURL(for itemId: UUID) -> URL {
        itemDirectoryURL(for: itemId).appendingPathComponent(AppFileConstants.manifestFileName)
    }

    func writeRecordingManifest(_ manifest: RecordingManifest, for itemId: UUID) throws {
        try createMeetingDirectory(for: itemId)
        let url = recordingManifestURL(for: itemId)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomicWrite)
    }

    func readRecordingManifest(for itemId: UUID) throws -> RecordingManifest {
        let url = recordingManifestURL(for: itemId)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    func recordingManifestExists(for itemId: UUID) -> Bool {
        fileManager.fileExists(atPath: recordingManifestURL(for: itemId).path)
    }

    /// Structured debug report of all recording artifacts for a meeting.
    /// Logs segment files, sizes, manifest validity, and audio.m4a status.
    /// Used on every Finish until route switching is stable.
    func debugRecordingArtifacts(meetingId: UUID) -> String {
        var lines: [String] = []
        let itemDir = meetingDirectoryURL(for: meetingId)
        lines.append("  itemId: \(meetingId.uuidString)")
        lines.append("  meetingDir: \(itemDir.path)")
        lines.append("  meetingDirExists: \(fileManager.fileExists(atPath: itemDir.path))")

        // Manifest
        let manifestExists = recordingManifestExists(for: meetingId)
        lines.append("  manifestExists: \(manifestExists)")

        var totalValidBytes: Int64 = 0
        var validSegmentCount = 0
        var segmentCount = 0

        if manifestExists, let manifest = try? readRecordingManifest(for: meetingId) {
            segmentCount = manifest.segments.count
            lines.append("  segmentCount: \(segmentCount)")
            for seg in manifest.segments {
                let url = segmentURL(for: meetingId, fileName: seg.fileName)
                let exists = fileManager.fileExists(atPath: url.path)
                let size: Int64 = exists ? (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 : 0
                let marker = size > 0 ? "✓" : "✗"
                lines.append("    \(seg.fileName): \(size) bytes \(marker) (endedAt=\(seg.endedAt?.description ?? "nil"))")
                if size > 0 { validSegmentCount += 1; totalValidBytes += size }
            }
            lines.append("  validSegmentCount: \(validSegmentCount)")
            lines.append("  totalValidSegmentBytes: \(totalValidBytes)")
        }

        // Single audio file
        let audioM4AURL = meetingDirectoryURL(for: meetingId).appendingPathComponent(AppFileConstants.audioFileName)
        let audioM4AExists = fileManager.fileExists(atPath: audioM4AURL.path)
        let audioM4ASize: Int64 = audioM4AExists ? (try? fileManager.attributesOfItem(atPath: audioM4AURL.path)[.size] as? Int64) ?? 0 : 0
        lines.append("  audioM4AExists: \(audioM4AExists)")
        lines.append("  audioM4ASize: \(audioM4ASize)")

        // Pipeline input decision
        let pipelineInput: String
        if audioM4AExists && audioM4ASize > 0 {
            pipelineInput = "audio.m4a"
        } else if validSegmentCount > 0 {
            pipelineInput = "manifest (\(validSegmentCount) valid segments)"
        } else {
            pipelineInput = "none — no valid audio"
        }
        lines.append("  pipelineInput: \(pipelineInput)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Artifacts

    func writeArtifact<T: Encodable>(_ value: T, fileName: String, meetingId: UUID) throws {
        try createMeetingDirectory(for: meetingId)
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

// MARK: - Recording Segment Model

/// One physical audio segment within a logical recording session.
struct RecordingSegment: Codable, Identifiable, Sendable {
    let id: UUID
    let index: Int
    let fileName: String      // e.g. "segment-000.m4a" (no directory prefix)
    let startedAt: Date
    var endedAt: Date?
    let inputPortName: String
    let inputPortType: String
    let routeChangeReason: String
    var sampleRate: Double?
    var fileSize: Int64?
}

/// Tracks all segments of a recording session.
struct RecordingManifest: Codable, Sendable {
    let recordingId: UUID
    let title: String
    let startedAt: Date
    var endedAt: Date?
    var segments: [RecordingSegment]

    var totalDuration: TimeInterval {
        segments.compactMap { seg in
            guard let end = seg.endedAt else { return nil }
            return end.timeIntervalSince(seg.startedAt)
        }.reduce(0, +)
    }
}
