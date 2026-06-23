import Foundation
import UniformTypeIdentifiers
// Related JIRA: KAN-12, KAN-62


final class SRTImporter: FormatImporter, @unchecked Sendable {
    let formatIdentifier = "srt"
    let displayName = "Subtitle (SRT)"
    let supportedUTTypes: [UTType] = [.plainText]

    func canRead(url: URL) -> Bool {
        url.pathExtension.lowercased() == "srt"
    }

    func canRead(data: Data) -> Bool {
        if let str = String(data: data.prefix(256), encoding: .utf8) {
            return str.contains("-->")
        }
        return false
    }

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        var warnings: [String] = []

        var segments: [TranscriptSegment] = []
        let itemId = UUID()
        let blocks = text.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count >= 2 else { continue }

            let timeLine = String(lines[1])
            guard timeLine.contains("-->") else { continue }

            let times = timeLine.components(separatedBy: "-->")
            guard times.count == 2 else { continue }

            let startTime = parseSRTTime(String(times[0]))
            let endTime = parseSRTTime(String(times[1]))
            let textLines = lines.dropFirst(2).map(String.init)
            let segmentText = textLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

            if !segmentText.isEmpty {
                segments.append(TranscriptSegment(
                    meetingId: itemId,
                    startTime: startTime,
                    endTime: endTime,
                    text: segmentText,
                    sourceEngineId: "srt_import"
                ))
            }
        }

        let item = KnowledgeItem(
            id: itemId,
            type: .audio,
            title: url.deletingPathExtension().lastPathComponent,
            status: .transcribed,
            durationSeconds: segments.last?.endTime
        )
        item.isImported = true
        item.importSourceURL = url.absoluteString
        item.transcriptionEngineId = "srt_import"

        let transcript = Transcript(meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: "srt_import")

        // Persist transcript to disk so pipeline and search can use it
        let fileStore = FileArtifactStore()
        do {
            try fileStore.createMeetingDirectory(for: item.id)
            try fileStore.writeArtifact(transcript, fileName: "transcript.json", meetingId: item.id)
        } catch {
            // Non-fatal: analysis can still run from bodyText
        }

        // Body text from segments for analysis pipeline
        item.bodyText = segments.map(\.text).joined(separator: " ")

        let transcriptURL = fileStore.itemDirectoryURL(for: item.id).appendingPathComponent("transcript.json")
        return ImportResult(knowledgeItem: item, artifacts: ["transcript.json": transcriptURL], warnings: warnings)
    }

    private func parseSRTTime(_ str: String) -> Double {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        // Format: HH:MM:SS,mmm
        var hours: Double = 0
        var minutes: Double = 0
        var seconds: Double = 0
        var millis: Double = 0

        let parts = cleaned.components(separatedBy: ":")
        if parts.count == 3 {
            hours = Double(parts[0]) ?? 0
            minutes = Double(parts[1]) ?? 0
            let secParts = parts[2].components(separatedBy: ",")
            seconds = Double(secParts[0]) ?? 0
            millis = Double(secParts[safe: 1] ?? "0") ?? 0
        }
        return hours * 3600 + minutes * 60 + seconds + millis / 1000.0
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
