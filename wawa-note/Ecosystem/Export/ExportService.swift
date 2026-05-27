import Foundation

final class ExportService {
    private let markdownExporter = MarkdownExporter()
    private let jsonExporter = JSONExporter()

    func exportMarkdown(item: KnowledgeItem, transcript: Transcript?, analysis: MeetingAnalysis?) -> String {
        markdownExporter.export(item: item, transcript: transcript, analysis: analysis)
    }

    func exportJSON(item: KnowledgeItem, transcript: Transcript?, analysis: MeetingAnalysis?) throws -> Data {
        try jsonExporter.export(item: item, transcript: transcript, analysis: analysis)
    }

    func exportSRT(transcript: Transcript) -> String {
        var srt = ""
        let groups = transcript.groupedSegments(pauseThreshold: 0.5, maxChars: 80)
        for (i, group) in groups.enumerated()
        where !group.text.trimmingCharacters(in: .whitespaces).isEmpty {
            srt += "\(i + 1)\n"
            srt += "\(formatSRTTime(group.startTime)) --> \(formatSRTTime(group.endTime))\n"
            srt += "\(group.text)\n\n"
        }
        return srt
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
