import Foundation

// Related JIRA: KAN-12, KAN-64

struct MarkdownExporter: Sendable {

    func export(
        item: KnowledgeItem,
        transcript: Transcript?,
        analysis: MeetingAnalysis?
    ) -> String {
        var md = ""

        // YAML frontmatter
        md += "---\n"
        let escapedTitle = item.title.replacingOccurrences(of: "\"", with: "\\\"")
        md += "title: \"\(escapedTitle)\"\n"
        md += "date: \(ISO8601DateFormatter().string(from: item.createdAt))\n"
        md += "type: \(item.type.rawValue)\n"
        if let duration = item.durationSeconds { md += "duration: \(Int(duration))\n" }
        if !item.tags.isEmpty { md += "tags: [\(item.tags.joined(separator: ", "))]\n" }
        md += "status: \(item.status.rawValue)\n"
        md += "---\n\n"

        md += "# \(item.title.isEmpty ? "Untitled" : item.title)\n\n"
        md += "**Date:** \(item.createdAt.formatted(date: .long, time: .shortened))\n"
        if let duration = item.durationSeconds {
            md += "**Duration:** \(formatDuration(duration))\n"
        }
        md += "**Type:** \(item.type.rawValue.capitalized)\n"
        md += "**Status:** \(item.status.rawValue.capitalized)\n"
        md += "\n---\n\n"

        if let analysis {
            if !analysis.shortSummary.isEmpty {
                md += "## Summary\n\n\(analysis.shortSummary)\n\n"
            }

            if !analysis.actionItems.isEmpty {
                md += "## Action Items\n\n"
                for action in analysis.actionItems {
                    md += "- [ ] **\(action.task)**"
                    if let owner = action.owner { md += " — \(owner)" }
                    md += "\n"
                }
                md += "\n"
            }

            if !analysis.decisions.isEmpty {
                md += "## Decisions\n\n"
                for decision in analysis.decisions {
                    md += "- **\(decision.title)**\n"
                    if !decision.details.isEmpty { md += "  \(decision.details)\n" }
                }
                md += "\n"
            }

            if !analysis.risks.isEmpty {
                md += "## Risks\n\n"
                for risk in analysis.risks {
                    md += "- **\(risk.risk)**\n"
                    if !risk.details.isEmpty { md += "  \(risk.details)\n" }
                }
                md += "\n"
            }

            if !analysis.openQuestions.isEmpty {
                md += "## Open Questions\n\n"
                for q in analysis.openQuestions {
                    md += "- \(q.question)\n"
                }
                md += "\n"
            }

            if !analysis.detailedSummary.isEmpty && analysis.detailedSummary != analysis.shortSummary {
                md += "## Detailed Summary\n\n\(analysis.detailedSummary)\n\n"
            }
        }

        if let transcript {
            md += "## Transcript\n\n"
            for group in transcript.groupedSegments() {
                let time = formatTime(group.startTime)
                md += "**[\(time)]** \(group.text)\n\n"
            }
        } else if let body = item.bodyText, !body.isEmpty {
            md += "## Content\n\n\(body)\n\n"
        }

        md += "\n---\n*Exported by Wawa Note*\n"
        return md
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        if m >= 60 {
            let h = m / 60
            let remainingM = m % 60
            return "\(h)h \(remainingM)m \(s)s"
        }
        if s > 0 { return "\(m)m \(s)s" }
        return "\(m)m"
    }
}
