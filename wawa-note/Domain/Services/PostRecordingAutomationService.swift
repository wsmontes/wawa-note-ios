import Foundation
import SwiftData

// Related JIRA: KAN-5, KAN-14

// MARK: - Notifications

// MARK: - App notifications
// Centralized definitions. Prefer @Published on services over NotificationCenter
// when possible. These remain for cross-service events that don't share an ObservableObject.

extension Notification.Name {
    static let transcriptReady = Notification.Name("PostRecordingTranscriptReady")
    static let analysisReady = Notification.Name("PostRecordingAnalysisReady")
    static let processingStageChanged = Notification.Name("PostRecordingStageChanged")
    static let pipelineCompleted = Notification.Name("WawaPipelineCompleted")
    static let contentPipelineStageChanged = Notification.Name("ContentPipelineStageChanged")
}

// MARK: - Project ingestion state

/// Tracks which projects are currently being enriched, so views can show progress.
/// Uses @Published for ingestion events (preferred over NotificationCenter).
@MainActor
final class ProjectIngestionState: ObservableObject {
    @Published var activeProjectIDs: Set<UUID> = []
    @Published var ingestionErrors: [UUID: String] = [:]
    @Published var ingestionVersion = 0

    init() {}

    func start(_ projectID: UUID) {
        activeProjectIDs.insert(projectID)
        ingestionErrors[projectID] = nil
    }

    func finish(_ projectID: UUID) {
        activeProjectIDs.remove(projectID)
        ingestionVersion += 1
    }

    func setError(_ projectID: UUID, message: String) {
        ingestionErrors[projectID] = message
        activeProjectIDs.remove(projectID)
        ingestionVersion += 1
    }
}

// MARK: - Shared context builder

/// Shared logic for building AI prompt context from KnowledgeItems and analysis artifacts.
/// Used by ProjectConversionService.
enum ItemContextBuilder {

    static func buildItemContext(item: KnowledgeItem, fileStore: FileArtifactStore) -> String {
        var ctx = ""
        ctx += "Title: \(item.title.isEmpty ? "Untitled" : item.title)\n"
        ctx += "UUID: \(item.id.uuidString)\n"
        ctx += "Type: \(item.type.label) | Created: \(item.createdAt.formatted(date: .complete, time: .shortened))\n"
        if let dur = item.durationSeconds { ctx += "Duration: \(Int(dur/60))m \(Int(dur)%60)s\n" }
        if !item.tags.isEmpty { ctx += "Tags: \(item.tags.joined(separator: ", "))\n" }

        if let body = item.bodyText, !body.isEmpty {
            let preview = body.count > 3000 ? String(body.prefix(3000)) + "\n...[truncated, \(body.count) total chars]" : body
            ctx += "\nCONTENT:\n\(preview)\n"
        }

        if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            ctx += "\nANALYSIS:\n"
            ctx += "Summary: \(analysis.shortSummary)\n"
            if !analysis.detailedSummary.isEmpty {
                let detail =
                    analysis.detailedSummary.count > 2000
                    ? String(analysis.detailedSummary.prefix(2000)) + "...[truncated]"
                    : analysis.detailedSummary
                ctx += "Detailed: \(detail)\n"
            }
            if !analysis.decisions.isEmpty {
                ctx += "\nDecisions:\n" + analysis.decisions.map { "- \($0.title)" }.joined(separator: "\n") + "\n"
            }
            if !analysis.actionItems.isEmpty {
                ctx +=
                    "\nAction Items:\n"
                    + analysis.actionItems.map { "- \($0.task) (owner: \($0.owner ?? "unassigned"), confidence: \(Int(($0.confidence ?? 0) * 100))%)" }.joined(
                        separator: "\n") + "\n"
            }
            if !analysis.risks.isEmpty {
                ctx += "\nRisks:\n" + analysis.risks.map { "- \($0.risk)" + ($0.details.isEmpty ? "" : ": \($0.details)") }.joined(separator: "\n") + "\n"
            }
            if !analysis.openQuestions.isEmpty {
                ctx += "\nOpen Questions:\n" + analysis.openQuestions.map { "- \($0.question)" }.joined(separator: "\n") + "\n"
            }
            if !analysis.entities.isEmpty {
                ctx += "\nEntities Mentioned:\n" + analysis.entities.map { "- \($0.name) (\($0.type.rawValue))" }.joined(separator: "\n") + "\n"
            }
        } else if let dynamic = try? fileStore.readArtifact(DynamicAnalysis.self, fileName: AppFileConstants.dynamicAnalysisFileName, meetingId: item.id),
            let summary = dynamic.results.stringField("short_summary")
        {
            ctx += "\nANALYSIS (dynamic):\n"
            ctx += "Summary: \(summary)\n"
        }

        return ctx
    }

    /// Compact summary for project context listing (title + key analysis fields).
    static func buildItemSummary(item: KnowledgeItem, fileStore: FileArtifactStore) -> String {
        var ctx = "[\(item.type.label)] \(item.title.isEmpty ? "Untitled" : item.title)\n"
        ctx += "   UUID: \(item.id.uuidString) | Created: \(item.createdAt.formatted(date: .abbreviated, time: .omitted))\n"
        if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            ctx += "   Summary: \(analysis.shortSummary)\n"
            if !analysis.decisions.isEmpty {
                ctx += "   Decisions: \(analysis.decisions.map(\.title).joined(separator: " | "))\n"
            }
            if !analysis.actionItems.isEmpty {
                ctx += "   Actions: \(analysis.actionItems.map { "\($0.task) (\($0.owner ?? "?"))" }.joined(separator: " | "))\n"
            }
            if !analysis.risks.isEmpty {
                ctx += "   Risks: \(analysis.risks.map(\.risk).joined(separator: " | "))\n"
            }
        } else if let dynamic = try? fileStore.readArtifact(DynamicAnalysis.self, fileName: AppFileConstants.dynamicAnalysisFileName, meetingId: item.id),
            let summary = dynamic.results.stringField("short_summary")
        {
            ctx += "   Summary: \(summary)\n"
        }
        return ctx
    }

    static func findItem(byTitle title: String, in items: [KnowledgeItem]) -> KnowledgeItem? {
        if let exact = items.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
            return exact
        }
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return items.first { item in
            let itemLower = item.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return itemLower.contains(lower) || lower.contains(itemLower)
        }
    }

    static func findTask(byTitle title: String, in tasks: [TaskItem]) -> TaskItem? {
        if let exact = tasks.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
            return exact
        }
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.first { task in
            let taskLower = task.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return taskLower.contains(lower) || lower.contains(taskLower)
        }
    }
}
