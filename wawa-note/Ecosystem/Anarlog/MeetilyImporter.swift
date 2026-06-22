import Foundation
import UniformTypeIdentifiers
import OSLog
// Related JIRA: KAN-12, KAN-63


/// Imports Meetily meeting data as KnowledgeItem records.
///
/// Meetily stores data in SQLite (meetings + transcripts + summary_processes).
/// This importer handles two formats:
///
/// 1. **Meetily JSON export** — the `summary_processes.result` JSON with
///    transcript, summary, action_items, key_points, metadata.
///
/// 2. **Plain transcript text** — direct transcript import with auto-detection
///    of Meetily-style speaker labels (e.g., "Speaker A:", "John:").
///
/// Meetily JSON format:
/// ```json
/// {
///   "meeting": {"id": "...", "title": "...", "created_at": "...", "updated_at": "..."},
///   "transcript": "full transcript text...",
///   "summary": "# Summary\n...",
///   "action_items": "- [ ] Task 1 | owner: Alice\n- [ ] Task 2",
///   "key_points": "- Key point 1\n- Key point 2",
///   "notes_markdown": "# Notes\n...",
///   "metadata": {"model": "whisper-large", "duration_secs": 3600, ...}
/// }
/// ```
struct MeetilyImporter: FormatImporter {
    let formatIdentifier = "meetily/v1"
    let displayName = "Meetily Meeting"
    let supportedUTTypes: [UTType] = [.json, .plainText, UTType(filenameExtension: "meetily")!]
    let priority = 16  // Just above anarlog

    private let fileStore = FileArtifactStore()
    private let logger = Logger(subsystem: "com.wawa.note", category: "MeetilyImporter")

    // MARK: - Detection

    func canRead(url: URL) -> Bool {
        // Check file extension first
        let ext = url.pathExtension.lowercased()
        if ext == "meetily" { return true }

        guard let data = try? Data(contentsOf: url) else { return false }

        // Try JSON format
        if ext == "json", let content = String(data: data, encoding: .utf8) {
            return isMeetilyJSON(content)
        }

        // Try plain text transcript
        if let content = String(data: data, encoding: .utf8) {
            return isMeetilyTranscript(content)
        }

        return false
    }

    func canRead(data: Data) -> Bool {
        guard let content = String(data: data, encoding: .utf8) else { return false }
        return isMeetilyJSON(content) || isMeetilyTranscript(content)
    }

    private func isMeetilyJSON(_ content: String) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: content.data(using: .utf8)!) as? [String: Any] else {
            return false
        }
        // Meetily JSON has either "meeting" + "transcript" or "transcript" + "summary"
        return (json["meeting"] != nil && json["transcript"] != nil) ||
               (json["transcript"] != nil && json["summary"] != nil)
    }

    private func isMeetilyTranscript(_ content: String) -> Bool {
        // Detect Meetily-style speaker labels
        let speakerPattern = try? NSRegularExpression(
            pattern: #"^(Speaker \w+|\[\d{2}:\d{2}\])\s"#,
            options: [.anchorsMatchLines]
        )
        let range = NSRange(content.startIndex..., in: content)
        let matches = speakerPattern?.numberOfMatches(in: content, range: range) ?? 0
        // At least 3 speaker-labeled lines to count as Meetily transcript
        return matches >= 3
    }

    // MARK: - Import

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        if ext == "json" || ext == "meetily" {
            return try await importJSON(data, sourceURL: url)
        } else {
            return try await importTranscript(data, sourceURL: url)
        }
    }

    // MARK: - JSON import

    private func importJSON(_ data: Data, sourceURL: URL) async throws -> ImportResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidJSON
        }

        let meeting = json["meeting"] as? [String: Any]
        let title = meeting?["title"] as? String ?? sourceURL.deletingPathExtension().lastPathComponent
        let createdAt: Date
        if let dateStr = meeting?["created_at"] as? String {
            createdAt = ISO8601DateFormatter().date(from: dateStr) ?? Date()
        } else {
            createdAt = Date()
        }

        let transcriptText = json["transcript"] as? String ?? ""
        let summaryText = json["summary"] as? String
        let actionItems = json["action_items"] as? String
        let keyPoints = json["key_points"] as? String
        let notesMarkdown = json["notes_markdown"] as? String
        let metadata = json["metadata"] as? [String: Any]

        // Build bodyText
        var bodyParts: [String] = []
        if let summary = summaryText, !summary.isEmpty {
            bodyParts.append(summary)
        }
        if let notes = notesMarkdown, !notes.isEmpty {
            bodyParts.append(notes)
        }
        let bodyText = bodyParts.isEmpty ? nil : bodyParts.joined(separator: "\n\n---\n\n")

        let item = KnowledgeItem(
            id: UUID(),
            type: .note,
            title: title,
            createdAt: createdAt,
            updatedAt: Date(),
            status: .analyzed,
            tags: [],
            isFlagged: false,
            bodyText: bodyText,
            durationSeconds: metadata?["duration_secs"] as? Double,
            languageCode: metadata?["language"] as? String,
            inboxDate: Date()
        )
        item.isImported = true
        item.importSourceURL = sourceURL.lastPathComponent

        var warnings: [String] = []

        // Store transcript as artifact
        if !transcriptText.isEmpty {
            let transcriptData = MeetilyTranscriptJSON(
                text: transcriptText,
                actionItems: actionItems,
                keyPoints: keyPoints,
                metadata: metadata
            )
            do {
                try fileStore.writeArtifact(transcriptData, fileName: "meetily_transcript.json", meetingId: item.id)
            } catch {
                warnings.append("Failed to persist Meetily transcript: \(error.localizedDescription)")
            }
        }

        // Store full import provenance for round-trip
        item.fieldProvenanceJSON = try? JSONEncoder().encode(
            MeetilyImportProvenance(
                sourceURL: sourceURL.lastPathComponent,
                meetingID: meeting?["id"] as? String,
                importedAt: Date()
            )
        ).base64EncodedString()

        // Copy original file
        do {
            try fileStore.createMeetingDirectory(for: item.id)
            let dest = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("meetily_original.json")
            try data.write(to: dest, options: .atomic)
        } catch {
            warnings.append("Failed to preserve original: \(error.localizedDescription)")
        }

        logger.info("Imported Meetily meeting '\(title)' → \(item.id)")
        return ImportResult(knowledgeItem: item, artifacts: ["transcript": fileStore.itemDirectoryURL(for: item.id)], warnings: warnings)
    }

    // MARK: - Transcript import (plain text)

    private func importTranscript(_ data: Data, sourceURL: URL) async throws -> ImportResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidEncoding
        }

        let title = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // Parse speaker segments from Meetily-style transcript
        let segments = parseSpeakerSegments(text)

        let item = KnowledgeItem(
            id: UUID(),
            type: .note,
            title: title,
            createdAt: Date(),
            updatedAt: Date(),
            status: .transcribed,
            tags: [],
            isFlagged: false,
            bodyText: text,
            inboxDate: Date()
        )
        item.isImported = true
        item.importSourceURL = sourceURL.lastPathComponent

        var warnings: [String] = []

        // Store parsed segments
        if !segments.isEmpty {
            let transcriptData = MeetilyTranscriptJSON(
                text: text,
                actionItems: nil,
                keyPoints: nil,
                metadata: ["segment_count": segments.count]
            )
            do {
                try fileStore.writeArtifact(transcriptData, fileName: "meetily_transcript.json", meetingId: item.id)
            } catch {
                warnings.append("Failed to persist transcript: \(error.localizedDescription)")
            }
        }

        logger.info("Imported Meetily transcript '\(title)' → \(item.id) (\(segments.count) speakers)")
        return ImportResult(knowledgeItem: item, artifacts: [:], warnings: warnings)
    }

    // MARK: - Speaker parsing

    /// Parse Meetily-style speaker labels from transcript text.
    /// Formats: "Speaker A: text", "[00:05:30] John: text", "Alice (CEO): text"
    private func parseSpeakerSegments(_ text: String) -> [MeetilySpeakerSegment] {
        let pattern = try? NSRegularExpression(
            pattern: #"^(?:\[(\d{2}:\d{2}:\d{2})\]\s*)?([A-Z][^:]{1,30}):\s*(.+)$"#,
            options: [.anchorsMatchLines]
        )

        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern?.matches(in: text, range: range) ?? []

        return matches.compactMap { match in
            guard match.numberOfRanges >= 4 else { return nil }

            let timestamp = match.range(at: 1).location != NSNotFound
                ? (text as NSString).substring(with: match.range(at: 1))
                : nil
            let speaker = (text as NSString).substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
            let content = (text as NSString).substring(with: match.range(at: 3))
                .trimmingCharacters(in: .whitespaces)

            return MeetilySpeakerSegment(
                timestamp: timestamp,
                speaker: speaker,
                text: content
            )
        }
    }

    // MARK: - Types

    struct MeetilyTranscriptJSON: Codable {
        let text: String
        let actionItems: String?
        let keyPoints: String?
        let metadata: [String: Any]?

        enum CodingKeys: String, CodingKey {
            case text
            case actionItems = "action_items"
            case keyPoints = "key_points"
            case metadata
        }

        init(text: String, actionItems: String?, keyPoints: String?, metadata: [String: Any]?) {
            self.text = text
            self.actionItems = actionItems
            self.keyPoints = keyPoints
            self.metadata = metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            actionItems = try container.decodeIfPresent(String.self, forKey: .actionItems)
            keyPoints = try container.decodeIfPresent(String.self, forKey: .keyPoints)
            // metadata as raw JSON
            if let data = try? container.decode(Data.self, forKey: .metadata) {
                metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            } else {
                metadata = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(actionItems, forKey: .actionItems)
            try container.encodeIfPresent(keyPoints, forKey: .keyPoints)
            if let metadata {
                let data = try JSONSerialization.data(withJSONObject: metadata)
                try container.encode(data, forKey: .metadata)
            }
        }
    }

    struct MeetilySpeakerSegment: Codable {
        let timestamp: String?
        let speaker: String
        let text: String
    }

    private struct MeetilyImportProvenance: Codable {
        let sourceURL: String
        let meetingID: String?
        let importedAt: Date
    }

    enum ImportError: Error, LocalizedError {
        case invalidJSON
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .invalidJSON: "File is not valid Meetily JSON"
            case .invalidEncoding: "File is not valid UTF-8"
            }
        }
    }
}
