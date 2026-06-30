import Foundation
import OSLog
import UniformTypeIdentifiers

// Related JIRA: KAN-12, KAN-63

/// Imports anarlog `.md` session notes as KnowledgeItem records.
///
/// Detects anarlog documents by checking for valid YAML frontmatter
/// with anarlog-specific fields (participants, transcript, session, template).
/// Non-anarlog markdown files fall through to the next importer in the chain.
struct AnarlogImporter: FormatImporter {
    let formatIdentifier = "anarlog/markdown-v1"
    let displayName = "Anarlog Session Note"
    let supportedUTTypes: [UTType] = [.plainText, UTType(filenameExtension: "md")!]
    let priority = 15  // Higher than generic text importers, lower than native formats

    private let fileStore = FileArtifactStore()
    private let logger = Logger(subsystem: "com.wawa.note", category: "AnarlogImporter")

    // MARK: - Detection

    func canRead(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let content = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return isAnarlogDocument(content)
    }

    func canRead(data: Data) -> Bool {
        guard let content = String(data: data, encoding: .utf8) else {
            return false
        }
        return isAnarlogDocument(content)
    }

    /// Check if the content looks like an anarlog document.
    /// Must have YAML frontmatter with at least one anarlog-specific key.
    private func isAnarlogDocument(_ content: String) -> Bool {
        guard content.trimmingCharacters(in: .whitespaces).hasPrefix("---") else {
            return false
        }
        // Try to parse — if it succeeds and has anarlog-specific fields, it's ours
        guard let doc = try? AnarlogDocument.parse(from: content) else {
            return false
        }
        let fm = doc.frontmatter
        // At least one anarlog-specific field
        return fm.participants != nil || fm.transcript != nil || fm.session != nil || fm.template != nil || fm.duration != nil
    }

    // MARK: - Import

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ImportError.invalidEncoding
        }

        let doc = try AnarlogDocument.parse(from: content)
        let fm = doc.frontmatter

        // Resolve title
        let title: String
        if let fmTitle = fm.title, !fmTitle.isEmpty {
            title = fmTitle
        } else {
            title = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        }

        // Get file modification date as fallback
        let fileDate: Date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modDate = attrs[.modificationDate] as? Date
        {
            fileDate = modDate
        } else {
            fileDate = Date()
        }

        // Create KnowledgeItem
        let item = KnowledgeItem(
            id: UUID(),
            type: .note,
            title: title,
            createdAt: fm.date ?? fileDate,
            updatedAt: Date(),
            status: .analyzed,  // Already processed by anarlog
            tags: fm.tags ?? [],
            isFlagged: false,
            bodyText: doc.content,
            durationSeconds: fm.duration,
            languageCode: nil,
            inboxDate: Date()  // Goes to inbox for review
        )
        item.isImported = true
        item.importSourceURL = url.lastPathComponent

        // Store original markdown for round-trip fidelity
        item.fieldProvenanceJSON = try? JSONEncoder().encode(
            AnarlogImportProvenance(
                sourceURL: url.lastPathComponent,
                originalFrontmatter: fm,
                importedAt: Date()
            )
        ).base64EncodedString()

        // Persist transcript data if present.
        // Must use the canonical `Transcript` schema so search, export, embeddings,
        // and the VFS can read it via readArtifact(Transcript.self, ...). (KAN-518)
        var warnings: [String] = []
        if let transcript = fm.transcript, !transcript.segments.isEmpty {
            let canonicalSegments: [TranscriptSegment] = transcript.segments.enumerated().map { idx, seg in
                let speaker = seg.speaker.trimmingCharacters(in: .whitespaces)
                let text = speaker.isEmpty ? seg.text : "\(speaker): \(seg.text)"
                return TranscriptSegment(
                    meetingId: item.id,
                    startTime: Double(idx),
                    endTime: nil,
                    text: text,
                    languageCode: nil,
                    sourceEngineId: "anarlog_import"
                )
            }
            let canonicalTranscript = Transcript(
                meetingId: item.id,
                languageCode: nil,
                segments: canonicalSegments,
                sourceEngineId: "anarlog_import"
            )
            do {
                try fileStore.writeArtifact(canonicalTranscript, fileName: "transcript.json", meetingId: item.id)
                item.transcriptionEngineId = "anarlog_import"
            } catch {
                warnings.append("Failed to persist transcript: \(error.localizedDescription)")
                logger.warning("Failed to persist transcript for \(item.id): \(error)")
            }
        }

        // Copy original .md file to item directory for round-trip
        do {
            try fileStore.createMeetingDirectory(for: item.id)
            let destURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("anarlog_original.md")
            try FileManager.default.copyItem(at: url, to: destURL)
        } catch {
            warnings.append("Failed to preserve original file: \(error.localizedDescription)")
            logger.warning("Failed to copy original anarlog file: \(error)")
        }

        logger.info("Imported anarlog note '\(title)' → \(item.id)")

        return ImportResult(
            knowledgeItem: item,
            artifacts: ["transcript": fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("transcript.json")],
            warnings: warnings
        )
    }

    enum ImportError: Error, LocalizedError {
        case invalidEncoding
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidEncoding: return "File is not valid UTF-8"
            case .parseFailed(let msg): return "Failed to parse anarlog document: \(msg)"
            }
        }
    }
}

// MARK: - Import provenance (stored in fieldProvenanceJSON)

private struct AnarlogImportProvenance: Codable {
    let sourceURL: String
    let originalFrontmatter: AnarlogFrontmatter
    let importedAt: Date
}
