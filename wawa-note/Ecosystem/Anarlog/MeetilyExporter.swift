import Foundation
import OSLog

/// Exports Wawa Note KnowledgeItem records as Meetily-compatible JSON.
///
/// Meetily stores meetings with this structure:
/// ```json
/// {
///   "meeting": {"id": "...", "title": "...", "created_at": "...", "updated_at": "..."},
///   "transcript": "full transcript text with speaker labels...",
///   "summary": "# Summary\n\nmarkdown summary...",
///   "action_items": "- [ ] Task | owner: Alice | due: 2025-06-15",
///   "key_points": "- Key insight 1\n- Key insight 2\n- Decision: X",
///   "notes_markdown": "# User Notes\n...",
///   "metadata": {"model": "claude-sonnet-4-6", "duration_secs": 3600, "language": "en", "exported_from": "Wawa Note"}
/// }
/// ```
///
/// The exporter also supports:
/// - Batch export: multiple items → Meetily-compatible directory
/// - Template-based summary formatting via MeetilyTemplateService
struct MeetilyExporter {
    private let fileStore: FileArtifactStore
    private let logger = Logger(subsystem: "com.wawa.note", category: "MeetilyExporter")

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
    }

    // MARK: - Export JSON

    /// Export a single KnowledgeItem as Meetily-compatible JSON.
    func exportJSON(
        item: KnowledgeItem,
        transcript: String? = nil,
        analysis: MeetingAnalysis? = nil
    ) throws -> Data {
        var json: [String: Any] = [:]

        // Meeting metadata
        json["meeting"] = [
            "id": item.id.uuidString,
            "title": item.title,
            "created_at": ISO8601DateFormatter().string(from: item.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: item.updatedAt),
        ]

        // Transcript
        if let transcriptText = transcript {
            json["transcript"] = transcriptText
        } else if let bodyText = item.bodyText {
            json["transcript"] = bodyText
        } else {
            json["transcript"] = ""
        }

        // Summary (from analysis)
        if let analysis = analysis {
            if !analysis.shortSummary.isEmpty || !analysis.detailedSummary.isEmpty {
                let summaryParts = [
                    analysis.shortSummary.isEmpty ? nil : analysis.shortSummary,
                    analysis.detailedSummary.isEmpty ? nil : analysis.detailedSummary,
                ].compactMap { $0 }
                json["summary"] = summaryParts.joined(separator: "\n\n")
            }

            // Action items
            if !analysis.actionItems.isEmpty {
                json["action_items"] = analysis.actionItems.map { a in
                    var parts = "- [ ] \(a.task)"
                    if let owner = a.owner { parts += " | owner: \(owner)" }
                    if let due = a.dueDate { parts += " | due: \(ISO8601DateFormatter().string(from: due))" }
                    return parts
                }.joined(separator: "\n")
            }

            // Key points (from decisions + risks + questions)
            var keyPoints: [String] = []
            for d in analysis.decisions {
                keyPoints.append("- Decision: \(d.title)")
                if !d.details.isEmpty { keyPoints.append("  \(d.details)") }
            }
            for r in analysis.risks {
                keyPoints.append("- Risk: \(r.risk)")
            }
            for q in analysis.openQuestions {
                keyPoints.append("- Question: \(q.question)")
            }
            if !keyPoints.isEmpty {
                json["key_points"] = keyPoints.joined(separator: "\n")
            }
        } else if let bodyText = item.bodyText {
            // No analysis — use bodyText as summary
            json["summary"] = bodyText
        }

        // Notes (from body if different from summary)
        if let bodyText = item.bodyText, analysis != nil {
            json["notes_markdown"] = bodyText
        }

        // Metadata
        var metadata: [String: Any] = [
            "exported_from": "Wawa Note",
            "wawa_item_id": item.id.uuidString,
            "wawa_item_type": item.type.rawValue,
        ]
        if let duration = item.durationSeconds {
            metadata["duration_secs"] = duration
        }
        if let lang = item.languageCode {
            metadata["language"] = lang
        }
        if let eventTitle = item.contextCalendarEventTitle {
            metadata["calendar_event"] = eventTitle
        }
        json["metadata"] = metadata

        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Export and write to a file URL.
    func exportToFile(
        item: KnowledgeItem,
        destination: URL,
        transcript: String? = nil,
        analysis: MeetingAnalysis? = nil
    ) throws {
        let data = try exportJSON(item: item, transcript: transcript, analysis: analysis)
        try data.write(to: destination, options: .atomic)
        logger.info("Exported Meetily JSON '\(item.title)' → \(destination.lastPathComponent)")
    }

    /// Export to the item's directory.
    func exportToItemDirectory(
        item: KnowledgeItem,
        transcript: String? = nil,
        analysis: MeetingAnalysis? = nil
    ) throws -> URL {
        let dir = fileStore.itemDirectoryURL(for: item.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let safeTitle = item.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let filename = "meetily_\(safeTitle).json"
        let destURL = dir.appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try exportToFile(item: item, destination: destURL, transcript: transcript, analysis: analysis)
        return destURL
    }

    // MARK: - Batch export

    /// Export multiple items to a directory (one .json file per meeting).
    func exportBatch(items: [KnowledgeItem], to directoryURL: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var exported: [URL] = []

        for item in items {
            // Try to load transcript and analysis for richer export
            let transcript: String?
            if let t = try? fileStore.readArtifact(MeetilyTranscriptJSON.self, fileName: "meetily_transcript.json", meetingId: item.id) {
                transcript = t.text
            } else if let t = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
                transcript = renderTranscript(t)
            } else {
                transcript = nil
            }

            let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)

            let safeTitle = item.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let fileURL = directoryURL.appendingPathComponent("\(safeTitle).json")
            try exportToFile(item: item, destination: fileURL, transcript: transcript, analysis: analysis)
            exported.append(fileURL)
        }

        logger.info("Batch exported \(exported.count) Meetily meetings to \(directoryURL.path)")
        return exported
    }

    // MARK: - Export transcript text (for direct copy)

    /// Export just the transcript text in Meetily speaker format.
    func exportTranscriptText(item: KnowledgeItem) throws -> String {
        // Try Meetily transcript first
        if let mt = try? fileStore.readArtifact(MeetilyTranscriptJSON.self, fileName: "meetily_transcript.json", meetingId: item.id) {
            return mt.text
        }
        // Try Wawa Note transcript
        if let t = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
            return renderTranscript(t)
        }
        // Fallback to body text
        return item.bodyText ?? ""
    }

    // MARK: - Helpers

    private func renderTranscript(_ transcript: Transcript) -> String {
        return transcript.segments.map { segment in
            let speakerLabel = segment.speakerId?.uuidString.prefix(8) ?? "Speaker"
            return "\(speakerLabel): \(segment.text)"
        }.joined(separator: "\n")
    }

    /// Local copy of MeetilyImporter's transcript JSON type for decoding.
    private struct MeetilyTranscriptJSON: Codable {
        let text: String
    }
}
