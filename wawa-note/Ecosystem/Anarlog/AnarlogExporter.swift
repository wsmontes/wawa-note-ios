import Foundation
import OSLog

/// Exports Wawa Note KnowledgeItem records as anarlog-compatible `.md` files.
///
/// Round-trip strategy:
/// 1. If the item was imported from anarlog, restore its original frontmatter
///    and merge in any Wawa Note enrichments (analysis, tasks, connections).
/// 2. If the item is native to Wawa Note, construct a fresh anarlog frontmatter
///    from item metadata, analysis, and project context.
struct AnarlogExporter {
    private let fileStore: FileArtifactStore
    private let logger = Logger(subsystem: "com.wawa.note", category: "AnarlogExporter")

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
    }

    // MARK: - Export single item

    /// Export a single KnowledgeItem as an anarlog-compatible `.md` string.
    /// - Parameters:
    ///   - item: The KnowledgeItem to export
    ///   - participants: Optional list of participants (from annotations or calendar)
    ///   - transcript: Optional transcript data (from FileArtifactStore)
    /// - Returns: Rendered anarlog markdown string
    func exportMarkdown(
        item: KnowledgeItem,
        participants: [AnarlogParticipant] = [],
        transcript: AnarlogTranscript? = nil
    ) throws -> String {
        let fm: AnarlogFrontmatter

        // Try to restore original frontmatter for round-trip fidelity
        if let provenanceB64 = item.fieldProvenanceJSON,
            let provenanceData = Data(base64Encoded: provenanceB64),
            let provenance = try? JSONDecoder().decode(AnarlogImportProvenance.self, from: provenanceData)
        {
            // Round-trip: restore original frontmatter
            fm = provenance.originalFrontmatter
        } else {
            // Fresh export: build frontmatter from Wawa Note metadata
            fm = buildFrontmatter(from: item, participants: participants, transcript: transcript)
        }

        // Enrich with any available participants or transcript
        var enrichedFM = fm
        if !participants.isEmpty {
            enrichedFM.participants = participants
        }
        if let transcript = transcript {
            enrichedFM.transcript = transcript
        }

        // Content: prefer bodyText, fall back to analysis summary
        let content: String
        if let bodyText = item.bodyText, !bodyText.isEmpty {
            content = bodyText
        } else if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            content = renderAnalysisAsMarkdown(analysis)
        } else {
            content = ""
        }

        let doc = AnarlogDocument(frontmatter: enrichedFM, content: content)
        return try doc.render()
    }

    /// Export and write to a file URL.
    func exportToFile(
        item: KnowledgeItem,
        destination: URL,
        participants: [AnarlogParticipant] = [],
        transcript: AnarlogTranscript? = nil
    ) throws {
        let markdown = try exportMarkdown(item: item, participants: participants, transcript: transcript)
        try markdown.write(to: destination, atomically: true, encoding: .utf8)
        logger.info("Exported anarlog note '\(item.title)' → \(destination.lastPathComponent)")
    }

    /// Export to the item's directory for later use.
    func exportToItemDirectory(
        item: KnowledgeItem,
        participants: [AnarlogParticipant] = [],
        transcript: AnarlogTranscript? = nil
    ) throws -> URL {
        let dir = fileStore.itemDirectoryURL(for: item.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let safeTitle = item.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = "anarlog_\(safeTitle).md"
        let destURL = dir.appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try exportToFile(item: item, destination: destURL, participants: participants, transcript: transcript)
        return destURL
    }

    // MARK: - Batch export

    /// Export multiple items to a directory, one `.md` file per item.
    func exportBatch(items: [KnowledgeItem], to directoryURL: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var exported: [URL] = []
        for item in items {
            let safeTitle = item.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let fileURL = directoryURL.appendingPathComponent("\(safeTitle).md")
            try exportToFile(item: item, destination: fileURL)
            exported.append(fileURL)
        }
        logger.info("Batch exported \(exported.count) items to \(directoryURL.path)")
        return exported
    }

    // MARK: - Private helpers

    private func buildFrontmatter(
        from item: KnowledgeItem,
        participants: [AnarlogParticipant],
        transcript: AnarlogTranscript?
    ) -> AnarlogFrontmatter {
        var fm = AnarlogFrontmatter()
        fm.title = item.title
        fm.date = item.createdAt
        fm.duration = item.durationSeconds
        fm.tags = item.tags.isEmpty ? nil : item.tags
        if !participants.isEmpty {
            fm.participants = participants
        }
        if let transcript = transcript {
            fm.transcript = transcript
        }
        // Session metadata from calendar context
        if let eventTitle = item.contextCalendarEventTitle {
            fm.session = AnarlogSession(
                title: eventTitle,
                startedAt: item.scheduledDate.map { ISO8601DateFormatter().string(from: $0) },
                endedAt: nil,
                event: AnarlogEvent(name: eventTitle)
            )
        }
        return fm
    }

    private func renderAnalysisAsMarkdown(_ analysis: MeetingAnalysis) -> String {
        var md = ""

        if !analysis.shortSummary.isEmpty {
            md += "# Summary\n\(analysis.shortSummary)\n\n"
        }

        if !analysis.decisions.isEmpty {
            md += "# Decisions\n"
            for d in analysis.decisions {
                md += "- **\(d.title)**"
                if !d.details.isEmpty { md += ": \(d.details)" }
                md += "\n"
            }
            md += "\n"
        }

        if !analysis.actionItems.isEmpty {
            md += "# Action Items\n"
            for a in analysis.actionItems {
                md += "- \(a.task)"
                if let owner = a.owner { md += " — \(owner)" }
                md += "\n"
            }
            md += "\n"
        }

        if !analysis.risks.isEmpty {
            md += "# Risks\n"
            for r in analysis.risks {
                md += "- \(r.risk)"
                if let c = r.confidence { md += " (confidence: \(Int(c * 100))%)" }
                md += "\n"
            }
            md += "\n"
        }

        if !analysis.openQuestions.isEmpty {
            md += "# Open Questions\n"
            for q in analysis.openQuestions {
                md += "- \(q.question)\n"
            }
            md += "\n"
        }

        return md.trimmingCharacters(in: .newlines)
    }
}

// MARK: - Reuse import provenance type from AnarlogImporter

private struct AnarlogImportProvenance: Codable {
    let sourceURL: String
    let originalFrontmatter: AnarlogFrontmatter
    let importedAt: Date
}
