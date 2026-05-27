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
        for (i, seg) in transcript.segments.enumerated()
        where !seg.text.trimmingCharacters(in: .whitespaces).isEmpty {
            srt += "\(i + 1)\n"
            srt += "\(formatSRTTime(seg.startTime)) --> \(formatSRTTime(seg.endTime ?? seg.startTime + 5.0))\n"
            srt += "\(seg.text)\n\n"
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
