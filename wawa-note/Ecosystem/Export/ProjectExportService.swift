import Foundation
import SwiftData
// Related JIRA: KAN-12, KAN-64


struct ProjectExportService {
    private let fileStore = FileArtifactStore()

    // MARK: - Project Markdown export

    /// Exports with pre-formatted task rows (from ProjectDerivedItem or other sources).
    func exportMarkdown(project: Project, items: [KnowledgeItem], tasks taskRows: [String], edges: [GraphEdge]) -> String {
        var md = "# \(project.name)\n\n"
        if let summary = project.summary, !summary.isEmpty { md += "\(summary)\n\n" }
        md += "**Status:** \(project.status.rawValue.capitalized)\n"
        md += "**Created:** \(project.createdAt.formatted(date: .long, time: .shortened))\n"
        md += "**Items:** \(items.count) | **Tasks:** \(taskRows.count) | **Connections:** \(edges.count)\n\n---\n\n"

        if !taskRows.isEmpty { md += "## Tasks\n\n\(taskRows.joined(separator: "\n"))\n\n" }

        if !items.isEmpty {
            md += "## Knowledge Items\n\n"
            for item in items {
                md += "### \(item.title.isEmpty ? "Untitled" : item.title)\n"
                md += "**Type:** \(item.type.label) | **Date:** \(item.createdAt.formatted(date: .abbreviated, time: .shortened))\n\n"
                if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
                    if !analysis.shortSummary.isEmpty { md += "\(analysis.shortSummary)\n\n" }
                    if !analysis.decisions.isEmpty {
                        md += "**Decisions:**\n"
                        for d in analysis.decisions { md += "- \(d.title)\n" }
                        md += "\n"
                    }
                }
            }
        }

        if !edges.isEmpty {
            md += "## Connections\n\n"
            for edge in edges.prefix(50) {
                md += "- \(edge.fromID.uuidString.prefix(8)) → [\(edge.edgeType.rawValue)] → \(edge.toID.uuidString.prefix(8))\n"
            }
            md += "\n"
        }
        return md
    }

    func exportMarkdown(project: Project, items: [KnowledgeItem], tasks: [TaskItem], edges: [GraphEdge]) -> String {
        var md = ""
        md += "# \(project.name)\n\n"

        if let summary = project.summary, !summary.isEmpty {
            md += "\(summary)\n\n"
        }

        md += "**Status:** \(project.status.rawValue.capitalized)\n"
        md += "**Created:** \(project.createdAt.formatted(date: .long, time: .shortened))\n"
        md += "**Items:** \(items.count) | **Tasks:** \(tasks.count) | **Connections:** \(edges.count)\n\n"
        md += "---\n\n"

        // Tasks section
        if !tasks.isEmpty {
            md += "## Tasks\n\n"
            for task in tasks {
                let check = task.status == .done ? "x" : " "
                md += "- [\(check)] **\(task.title)**"
                if let owner = task.ownerName { md += " — \(owner)" }
                if task.priority != .medium { md += " · \(task.priority.rawValue.capitalized)" }
                if let due = task.dueAt { md += " · Due: \(due.formatted(date: .abbreviated, time: .omitted))" }
                md += "\n"
            }
            md += "\n"
        }

        // Items section
        if !items.isEmpty {
            md += "## Knowledge Items\n\n"
            for item in items {
                md += "### \(item.title.isEmpty ? "Untitled" : item.title)\n"
                md += "**Type:** \(item.type.label) | **Date:** \(item.createdAt.formatted(date: .abbreviated, time: .shortened))\n\n"

                if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
                    if !analysis.shortSummary.isEmpty { md += "\(analysis.shortSummary)\n\n" }
                    if !analysis.decisions.isEmpty {
                        md += "**Decisions:**\n"
                        for d in analysis.decisions { md += "- \(d.title)\n" }
                        md += "\n"
                    }
                }
            }
        }

        // Connections section
        if !edges.isEmpty {
            md += "## Connections\n\n"
            for edge in edges {
                md += "- **\(edge.edgeType.rawValue.capitalized)**"
                if edge.provenanceItemID != nil { md += " [evidence-backed]" }
                md += "\n"
            }
            md += "\n"
        }

        md += "---\n*Exported by Wawa Note*\n"
        return md
    }

    // MARK: - Project JSON export

    func exportJSON(project: Project, items: [KnowledgeItem], tasks: [TaskItem], edges: [GraphEdge]) throws -> Data {
        let export = ProjectExport(
            version: "1.0",
            schema: "wawa-note/project/v1",
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            project: ProjectSummary(
                id: project.id.uuidString,
                name: project.name,
                slug: project.slug,
                summary: project.summary,
                status: project.status.rawValue,
                createdAt: ISO8601DateFormatter().string(from: project.createdAt)
            ),
            items: items.map { item in
                ItemSummary(
                    id: item.id.uuidString,
                    type: item.type.rawValue,
                    title: item.title,
                    createdAt: ISO8601DateFormatter().string(from: item.createdAt),
                    status: item.status.rawValue
                )
            },
            tasks: tasks.map { task in
                TaskSummary(
                    id: task.id.uuidString,
                    title: task.title,
                    status: task.status.rawValue,
                    priority: task.priority.rawValue,
                    owner: task.ownerName,
                    dueAt: task.dueAt.map { ISO8601DateFormatter().string(from: $0) },
                    sourceItemId: task.sourceItemID?.uuidString,
                    confidence: task.confidence
                )
            },
            edges: edges.map { edge in
                EdgeSummary(
                    id: edge.id.uuidString,
                    fromId: edge.fromID.uuidString,
                    toId: edge.toID.uuidString,
                    edgeType: edge.edgeType.rawValue,
                    weight: edge.weight,
                    provenanceItemId: edge.provenanceItemID?.uuidString
                )
            }
        )
        return try JSONEncoder().encode(export)
    }

    // MARK: - Graph JSON export

    func exportGraph(edges: [GraphEdge], allItems: [KnowledgeItem], allTasks: [TaskItem]) throws -> Data {
        var nodes: [GraphNodeExport] = []
        var seen: Set<String> = []

        for edge in edges {
            for (id, label, kind) in resolveNode(edge.fromID, items: allItems, tasks: allTasks) {
                let key = "\(kind):\(id)"
                if !seen.contains(key) {
                    seen.insert(key)
                    nodes.append(GraphNodeExport(id: id, label: label, kind: kind))
                }
            }
            for (id, label, kind) in resolveNode(edge.toID, items: allItems, tasks: allTasks) {
                let key = "\(kind):\(id)"
                if !seen.contains(key) {
                    seen.insert(key)
                    nodes.append(GraphNodeExport(id: id, label: label, kind: kind))
                }
            }
        }

        let graph = GraphExport(
            version: "1.0",
            schema: "wawa-note/graph/v1",
            nodes: nodes,
            edges: edges.map {
                EdgeSummary(
                    id: $0.id.uuidString,
                    fromId: $0.fromID.uuidString,
                    toId: $0.toID.uuidString,
                    edgeType: $0.edgeType.rawValue,
                    weight: $0.weight,
                    provenanceItemId: $0.provenanceItemID?.uuidString
                )
            }
        )
        return try JSONEncoder().encode(graph)
    }

    // MARK: - Tasks CSV export

    func exportTasksCSV(tasks: [TaskItem]) -> String {
        var csv = "Title,Status,Priority,Owner,Due Date,Source Item,Created\n"
        for task in tasks {
            let title = task.title.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(title)\",\(task.status.rawValue),\(task.priority.rawValue),"
            csv += "\(task.ownerName ?? ""),\(task.dueAt?.formatted(date: .abbreviated, time: .omitted) ?? ""),"
            csv += "\(task.sourceItemID?.uuidString.prefix(8) ?? ""),\(task.createdAt.formatted(date: .abbreviated, time: .shortened))\n"
        }
        return csv
    }

    // MARK: - Helpers

    private func resolveNode(_ id: UUID, items: [KnowledgeItem], tasks: [TaskItem]) -> [(String, String, String)] {
        if let item = items.first(where: { $0.id == id }) {
            return [(item.id.uuidString, item.title.isEmpty ? "Untitled" : item.title, item.type.rawValue)]
        }
        if let task = tasks.first(where: { $0.id == id }) {
            return [(task.id.uuidString, task.title, "task")]
        }
        return [(id.uuidString, "Unknown", "unknown")]
    }
}

// MARK: - Export DTOs

private struct ProjectExport: Encodable {
    let version: String
    let schema: String
    let exportedAt: String
    let project: ProjectSummary
    let items: [ItemSummary]
    let tasks: [TaskSummary]
    let edges: [EdgeSummary]
}

private struct ProjectSummary: Encodable {
    let id: String
    let name: String
    let slug: String
    let summary: String?
    let status: String
    let createdAt: String
}

private struct ItemSummary: Encodable {
    let id: String
    let type: String
    let title: String
    let createdAt: String
    let status: String
}

private struct TaskSummary: Encodable {
    let id: String
    let title: String
    let status: String
    let priority: String
    let owner: String?
    let dueAt: String?
    let sourceItemId: String?
    let confidence: Double?
}

private struct EdgeSummary: Encodable {
    let id: String
    let fromId: String
    let toId: String
    let edgeType: String
    let weight: Double
    let provenanceItemId: String?
}

private struct GraphExport: Encodable {
    let version: String
    let schema: String
    let nodes: [GraphNodeExport]
    let edges: [EdgeSummary]
}

private struct GraphNodeExport: Encodable {
    let id: String
    let label: String
    let kind: String
}

// MARK: - Complete Instance Export

struct ExportStatistics: Codable {
    var projectCount: Int; var itemCount: Int; var taskCount: Int
    var personCount: Int; var entityCount: Int; var edgeCount: Int
    var signalCount: Int; var frameCount: Int; var snapshotCount: Int
    var changeCount: Int; var queueCount: Int; var promptCount: Int; var memoryCount: Int
}

// MARK: - Instance Export DTO (flat mirrors of all models)

struct InstanceExport: Codable {
    var version: Int; var schema: String; var exportedAt: String; var appVersion: String
    var statistics: ExportStatistics
    var projects: [ProjectExportFull]; var items: [ItemExportFull]; var tasks: [TaskExportFull]
    var people: [PersonExport]; var entities: [EntityExport]; var edges: [EdgeExportFull]
    var annotations: [AnnotationExport]; var signals: [SignalExport]; var frames: [FrameExport]
    var snapshots: [SnapshotExport]; var changeHistory: [ChangeRecordExport]?
    var queue: [QueueEntryExport]; var prompts: [PromptExport]; var memories: [MemoryExport]
    var config: ConfigExport
}

struct ProjectExportFull: Codable {
    var id: String; var name: String; var slug: String; var summary: String?; var synthesis: String?
    var customInstructions: String?; var frameworkId: String?; var frameworkJSON: String?
    var status: String; var colorHex: String?; var iconName: String?
    var createdAt: String; var updatedAt: String
    var healthScore: Double?; var healthStatus: String?; var lastActivityAt: String?
    var synthesisUpdatedAt: String?; var synthesisSourceItemID: String?
    var nameIsAutoGenerated: Bool; var fieldProvenanceJSON: String?
}

struct ItemExportFull: Codable {
    var id: String; var type: String; var title: String; var createdAt: String; var updatedAt: String
    var status: String; var tags: [String]; var bodyText: String?; var projectID: String?
    var folderID: String?; var isFlagged: Bool; var inboxDate: String?
    var durationSeconds: Double?; var languageCode: String?
    var audioFileRelativePath: String?; var imageFileRelativePath: String?; var imagePageCount: Int?
    var transcriptionEngineId: String?; var analysisProviderId: String?
    var calendarEventIdentifier: String?; var scheduledDate: String?
    var isImported: Bool; var importSourceURL: String?
    var contextCalendarEventTitle: String?; var contextPlaceName: String?
    var contextAudioRoute: String?; var contextLatitude: Double?; var contextLongitude: Double?
    var contextFocusActive: Bool?; var contextMotionActivity: String?; var contextBatteryLevel: Double?
    var fieldProvenanceJSON: String?
    var analysis: AnalysisExport?; var dynamicAnalysis: DynamicAnalysisExport?; var transcript: TranscriptExport?
}

struct AnalysisExport: Codable {
    var id: String; var providerId: String; var model: String?; var createdAt: String
    var shortSummary: String; var detailedSummary: String
    var decisions: [DecisionExport]; var actionItems: [ActionItemExport]
    var risks: [RiskExport]; var openQuestions: [QuestionExport]
    var importantDates: [DateExport]; var entities: [EntityMentionExport]
}
struct DecisionExport: Codable { var title: String; var details: String?; var confidence: Double? }
struct ActionItemExport: Codable { var task: String; var owner: String?; var dueDate: String?; var confidence: Double? }
struct RiskExport: Codable { var risk: String; var details: String?; var confidence: Double? }
struct QuestionExport: Codable { var question: String; var confidence: Double? }
struct DateExport: Codable { var date: String; var meaning: String? }
struct EntityMentionExport: Codable { var name: String; var type: String }

struct DynamicAnalysisExport: Codable {
    var id: String; var providerId: String; var model: String?; var schemaId: String
    var resultsJSON: String?
}

struct TranscriptExport: Codable {
    var meetingId: String?; var languageCode: String?; var sourceEngineId: String
    var createdAt: String; var segmentCount: Int; var segments: [TranscriptSegmentExport]
}
struct TranscriptSegmentExport: Codable {
    var id: String; var meetingId: String; var speakerId: String?; var text: String
    var startTime: Double; var endTime: Double?; var confidence: Double?
}

struct TaskExportFull: Codable {
    var id: String; var projectID: String?; var title: String; var status: String; var priority: String
    var ownerName: String?; var dueAt: String?; var sourceItemID: String?
    var sourceSegmentIDs: String?; var confidence: Double?; var notes: String?
    var createdAt: String; var updatedAt: String; var createdBy: String?; var fieldProvenanceJSON: String?
}

struct PersonExport: Codable {
    var id: String; var displayName: String; var canonicalKey: String
    var email: String?; var role: String?; var createdAt: String
}

struct EntityExport: Codable {
    var id: String; var kind: String; var displayName: String; var canonicalKey: String
}

struct EdgeExportFull: Codable {
    var id: String; var fromID: String; var toID: String; var edgeType: String
    var weight: Double; var provenanceItemID: String?; var provenanceSegmentIDs: String?; var createdAt: String
}

struct AnnotationExport: Codable {
    var id: String; var source: String; var key: String; var value: String
    var itemID: String; var createdAt: String; var confidence: Double?
}

struct SignalExport: Codable {
    var id: String; var projectID: String?; var type: String; var title: String; var body: String?
    var status: String; var confidence: Double?; var sourceItemID: String?; var sourceSegmentIDs: String?
    var payloadJSON: String?; var createdAt: String; var resolvedAt: String?
    var impactScore: Double?; var urgencyScore: Double?; var relevanceScore: Double?
    var resolutionReason: String?; var resolvedBy: String?; var isCritical: Bool
}

struct FrameExport: Codable {
    var id: String; var projectID: String; var parentFrameID: String?; var name: String
    var lensID: String?; var filterTags: [String]; var filterDateStart: String?; var filterDateEnd: String?
    var filterItemTypes: [String]; var createdAt: String
}

struct SnapshotExport: Codable {
    var id: String; var projectID: String; var label: String?; var trigger: String
    var createdAt: String; var changeCount: Int; var summary: String?
}

struct ChangeRecordExport: Codable {
    var id: String; var entityType: String; var entityID: String; var projectID: String?
    var field: String; var previousValue: String?; var newValue: String?
    var origin: String; var timestamp: String; var snapshotID: String?
}

struct QueueEntryExport: Codable {
    var id: String; var itemID: String; var projectID: String?; var status: String
    var priority: Int; var queuedAt: String; var startedAt: String?; var completedAt: String?
    var retryCount: Int; var maxRetries: Int; var lastError: String?; var position: Int
}

struct PromptExport: Codable {
    var name: String; var category: String; var content: String; var description: String?
    var variables: [String]; var updatedAt: String; var isUserEdited: Bool
}

struct MemoryExport: Codable {
    var id: String; var pattern: String; var strategy: String
    var itemType: String?; var contentType: String?; var language: String?
    var minDuration: Double?; var minChars: Int?
    var successCount: Int; var failCount: Int; var lastUsed: String; var createdAt: String
    var isStale: Bool; var relevance: Double
}

struct ConfigExport: Codable {
    var activeProviderID: String?; var preferredModel: String?
    var autoTranscribe: Bool; var autoAnalyze: Bool
    var autoAnalysisModel: String; var autoAnalysisProvider: String
}

// MARK: - Single Project Export DTO

struct SingleProjectExport: Codable {
    var version: Int; var schema: String; var exportedAt: String
    var project: ProjectExportFull
    var items: [ItemExportFull]; var tasks: [TaskExportFull]
    var people: [PersonExport]; var entities: [EntityExport]
    var edges: [EdgeExportFull]; var signals: [SignalExport]
    var frames: [FrameExport]; var snapshots: [SnapshotExport]
}

// MARK: - InstanceExportService

@MainActor
final class InstanceExportService {
    // MARK: Public helpers

    func buildItemExport(item: KnowledgeItem) -> ItemExportFull {
        let store = FileArtifactStore(); let iso = ISO8601DateFormatter()
        var analysis: AnalysisExport?
        if let a = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            analysis = AnalysisExport(id: a.id.uuidString, providerId: a.providerId, model: a.model,
                createdAt: iso.string(from: a.createdAt), shortSummary: a.shortSummary, detailedSummary: a.detailedSummary,
                decisions: a.decisions.map { DecisionExport(title: $0.title, details: $0.details, confidence: $0.confidence) },
                actionItems: a.actionItems.map { ActionItemExport(task: $0.task, owner: $0.owner, dueDate: $0.dueDate.map { iso.string(from: $0) }, confidence: $0.confidence) },
                risks: a.risks.map { RiskExport(risk: $0.risk, details: $0.details, confidence: $0.confidence) },
                openQuestions: a.openQuestions.map { QuestionExport(question: $0.question, confidence: $0.confidence) },
                importantDates: a.importantDates.map { DateExport(date: $0.date, meaning: $0.meaning) },
                entities: a.entities.map { EntityMentionExport(name: $0.name, type: $0.type.rawValue) })
        }
        var dynAnalysis: DynamicAnalysisExport?
        if let d = try? store.readArtifact(DynamicAnalysis.self, fileName: "analysis.dynamic.json", meetingId: item.id) {
            dynAnalysis = DynamicAnalysisExport(id: d.id.uuidString, providerId: d.providerId, model: d.model, schemaId: d.schemaId, resultsJSON: nil)
        }
        var transcript: TranscriptExport?
        if let t = try? store.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
            transcript = TranscriptExport(meetingId: t.meetingId.map({ $0.uuidString }), languageCode: t.languageCode,
                sourceEngineId: t.sourceEngineId, createdAt: iso.string(from: t.createdAt), segmentCount: t.segments.count,
                segments: t.segments.map { seg in TranscriptSegmentExport(id: seg.id.uuidString, meetingId: seg.meetingId.uuidString, speakerId: seg.speakerId.map({ $0.uuidString }), text: seg.text, startTime: seg.startTime, endTime: seg.endTime, confidence: seg.confidence) })
        }
        return ItemExportFull(id: item.id.uuidString, type: item.type.rawValue, title: item.title,
            createdAt: iso.string(from: item.createdAt), updatedAt: iso.string(from: item.updatedAt), status: item.status.rawValue,
            tags: item.tags, bodyText: item.bodyText, projectID: item.projectID.map({ $0.uuidString }),
            folderID: item.folderID.map({ $0.uuidString }), isFlagged: item.isFlagged, inboxDate: item.inboxDate.map({ iso.string(from: $0) }),
            durationSeconds: item.durationSeconds, languageCode: item.languageCode,
            audioFileRelativePath: item.audioFileRelativePath, imageFileRelativePath: item.imageFileRelativePath,
            imagePageCount: item.imagePageCount, transcriptionEngineId: item.transcriptionEngineId,
            analysisProviderId: item.analysisProviderId, calendarEventIdentifier: item.calendarEventIdentifier,
            scheduledDate: item.scheduledDate.map({ iso.string(from: $0) }), isImported: item.isImported, importSourceURL: item.importSourceURL,
            contextCalendarEventTitle: item.contextCalendarEventTitle, contextPlaceName: item.contextPlaceName,
            contextAudioRoute: item.contextAudioRoute, contextLatitude: item.contextLatitude,
            contextLongitude: item.contextLongitude, contextFocusActive: item.contextFocusActive,
            contextMotionActivity: item.contextMotionActivity, contextBatteryLevel: item.contextBatteryLevel,
            fieldProvenanceJSON: item.fieldProvenanceJSON, analysis: analysis, dynamicAnalysis: dynAnalysis, transcript: transcript)
    }

    func exportSingleProject(_ project: Project, context: ModelContext) -> SingleProjectExport {
        let pid = project.id; let items = (try? ProjectService(context: context).items(in: pid)) ?? []
        let allTasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        let tasks = allTasks.filter { $0.projectID == pid }
        let allEdges = (try? context.fetch(FetchDescriptor<GraphEdge>())) ?? []
        let itemIDs = Set(items.map(\.id))
        let edges = allEdges.filter { itemIDs.contains($0.fromID) || itemIDs.contains($0.toID) }
        let allPeople = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let allEntities = (try? context.fetch(FetchDescriptor<Entity>())) ?? []
        let allSignals = (try? context.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        let signals = allSignals.filter { $0.projectID == pid }
        let allFrames = (try? context.fetch(FetchDescriptor<ProjectFrame>())) ?? []
        let frames = allFrames.filter { $0.projectID == pid }
        let allSnapshots = (try? context.fetch(FetchDescriptor<ProjectSnapshot>())) ?? []
        let snapshots = allSnapshots.filter { $0.projectID == pid }
        return SingleProjectExport(version: 1, schema: "wawa-note/project-export/v2",
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            project: exportProjectFull(project),
            items: items.map(buildItemExport(item:)),
            tasks: tasks.map(exportTaskFull),
            people: allPeople.map(exportPerson),
            entities: allEntities.map(exportEntity),
            edges: edges.map(exportEdgeFull),
            signals: signals.map(exportSignal),
            frames: frames.map(exportFrame),
            snapshots: snapshots.map(exportSnapshot))
    }

    // MARK: Single-entity exporters (reused by exportSingleProject + exportComplete)

    private func exportProjectFull(_ p: Project) -> ProjectExportFull {
        ProjectExportFull(id: p.id.uuidString, name: p.name, slug: p.slug, summary: p.summary,
            synthesis: p.synthesis, customInstructions: p.customInstructions,
            frameworkId: p.frameworkId, frameworkJSON: p.frameworkJSON,
            status: p.status.rawValue, colorHex: p.colorHex, iconName: p.iconName,
            createdAt: iso.string(from: p.createdAt), updatedAt: iso.string(from: p.updatedAt),
            healthScore: p.healthScore, healthStatus: p.healthStatus,
            lastActivityAt: p.lastActivityAt.map({ iso.string(from: $0) }),
            synthesisUpdatedAt: p.synthesisUpdatedAt.map({ iso.string(from: $0) }),
            synthesisSourceItemID: p.synthesisSourceItemID.map({ $0.uuidString }),
            nameIsAutoGenerated: p.nameIsAutoGenerated, fieldProvenanceJSON: p.fieldProvenanceJSON)
    }

    private func exportTaskFull(_ t: TaskItem) -> TaskExportFull {
        TaskExportFull(id: t.id.uuidString, projectID: t.projectID.map({ $0.uuidString }), title: t.title,
            status: t.status.rawValue, priority: t.priority.rawValue, ownerName: t.ownerName,
            dueAt: t.dueAt.map({ iso.string(from: $0) }), sourceItemID: t.sourceItemID.map({ $0.uuidString }),
            sourceSegmentIDs: t.sourceSegmentIDs, confidence: t.confidence, notes: t.notes,
            createdAt: iso.string(from: t.createdAt), updatedAt: iso.string(from: t.updatedAt),
            createdBy: t.createdBy?.rawValue, fieldProvenanceJSON: t.fieldProvenanceJSON)
    }

    private func exportPerson(_ p: Person) -> PersonExport {
        PersonExport(id: p.id.uuidString, displayName: p.displayName, canonicalKey: p.canonicalKey,
            email: p.email, role: p.role, createdAt: iso.string(from: p.createdAt))
    }

    private func exportEntity(_ e: Entity) -> EntityExport {
        EntityExport(id: e.id.uuidString, kind: e.kind.rawValue, displayName: e.displayName, canonicalKey: e.canonicalKey)
    }

    private func exportEdgeFull(_ e: GraphEdge) -> EdgeExportFull {
        EdgeExportFull(id: e.id.uuidString, fromID: e.fromID.uuidString, toID: e.toID.uuidString,
            edgeType: e.edgeType.rawValue, weight: e.weight, provenanceItemID: e.provenanceItemID.map({ $0.uuidString }),
            provenanceSegmentIDs: e.provenanceSegmentIDs, createdAt: iso.string(from: e.createdAt))
    }

    private func exportSignal(_ sig: AgentSuggestion) -> SignalExport {
        SignalExport(id: sig.id.uuidString, projectID: sig.projectID.map({ $0.uuidString }), type: sig.type, title: sig.title,
            body: sig.body, status: sig.status, confidence: sig.confidence,
            sourceItemID: sig.sourceItemID.map({ $0.uuidString }), sourceSegmentIDs: sig.sourceSegmentIDs,
            payloadJSON: sig.payloadJSON, createdAt: iso.string(from: sig.createdAt), resolvedAt: sig.resolvedAt.map({ iso.string(from: $0) }),
            impactScore: sig.impactScore, urgencyScore: sig.urgencyScore, relevanceScore: sig.relevanceScore,
            resolutionReason: sig.resolutionReason, resolvedBy: sig.resolvedByRaw, isCritical: sig.isCritical)
    }

    private func exportFrame(_ f: ProjectFrame) -> FrameExport {
        FrameExport(id: f.id.uuidString, projectID: f.projectID.uuidString, parentFrameID: f.parentFrameID.map({ $0.uuidString }),
            name: f.name, lensID: f.lensID, filterTags: f.filterTags,
            filterDateStart: f.filterDateStart.map({ iso.string(from: $0) }), filterDateEnd: f.filterDateEnd.map({ iso.string(from: $0) }),
            filterItemTypes: f.filterItemTypes, createdAt: iso.string(from: f.createdAt))
    }

    private func exportSnapshot(_ snap: ProjectSnapshot) -> SnapshotExport {
        SnapshotExport(id: snap.id.uuidString, projectID: snap.projectID.uuidString, label: snap.label,
            trigger: snap.trigger.rawValue, createdAt: iso.string(from: snap.createdAt), changeCount: snap.changeCount, summary: snap.summary)
    }

    // MARK: - Complete export (private helpers reuse the above)
    private let store = FileArtifactStore()
    private let iso = ISO8601DateFormatter()

    func exportComplete(context: ModelContext, includeHistory: Bool = true) throws -> Data {
        let exp = try buildExport(context: context, includeHistory: includeHistory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exp)
    }

    func exportStatistics(context: ModelContext) -> ExportStatistics {
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let items = (try? context.fetch(FetchDescriptor<KnowledgeItem>())) ?? []
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let entities = (try? context.fetch(FetchDescriptor<Entity>())) ?? []
        let edges = (try? context.fetch(FetchDescriptor<GraphEdge>())) ?? []
        let signals = (try? context.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        let frames = (try? context.fetch(FetchDescriptor<ProjectFrame>())) ?? []
        let snapshots = (try? context.fetch(FetchDescriptor<ProjectSnapshot>())) ?? []
        let changes = (try? context.fetch(FetchDescriptor<ChangeRecord>())) ?? []
        let queue = (try? context.fetch(FetchDescriptor<QueueEntry>())) ?? []
        let prompts = PromptStore.shared.prompts(in: nil)
        let memories = AgentMemoryStore.shared.listAll()
        return ExportStatistics(projectCount: projects.count, itemCount: items.count, taskCount: tasks.count,
            personCount: people.count, entityCount: entities.count, edgeCount: edges.count,
            signalCount: signals.count, frameCount: frames.count, snapshotCount: snapshots.count,
            changeCount: changes.count, queueCount: queue.filter { $0.status == .queued || $0.status == .processing }.count,
            promptCount: prompts.count, memoryCount: memories.count)
    }

    private func buildExport(context: ModelContext, includeHistory: Bool) throws -> InstanceExport {
        let stats = exportStatistics(context: context)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        return InstanceExport(version: 1, schema: "wawa-note/instance-export-v1",
            exportedAt: iso.string(from: Date()), appVersion: appVersion, statistics: stats,
            projects: exportProjects(context: context), items: exportItems(context: context),
            tasks: exportTasks(context: context), people: exportPeople(context: context),
            entities: exportEntities(context: context), edges: exportEdges(context: context),
            annotations: exportAnnotations(context: context), signals: exportSignals(context: context),
            frames: exportFrames(context: context), snapshots: exportSnapshots(context: context),
            changeHistory: includeHistory ? exportHistory(context: context) : nil,
            queue: exportQueue(context: context), prompts: exportPrompts(), memories: exportMemories(),
            config: exportConfig())
    }

    private func s(_ date: Date) -> String { iso.string(from: date) }
    private func sid(_ id: UUID) -> String { id.uuidString }
    private func opt(_ uuid: UUID?) -> String? { uuid?.uuidString }

    private func exportProjects(context: ModelContext) -> [ProjectExportFull] {
        (try? context.fetch(FetchDescriptor<Project>()))?.map { p in
            ProjectExportFull(id: sid(p.id), name: p.name, slug: p.slug, summary: p.summary,
                synthesis: p.synthesis, customInstructions: p.customInstructions,
                frameworkId: p.frameworkId, frameworkJSON: p.frameworkJSON,
                status: p.status.rawValue, colorHex: p.colorHex, iconName: p.iconName,
                createdAt: s(p.createdAt), updatedAt: s(p.updatedAt),
                healthScore: p.healthScore, healthStatus: p.healthStatus,
                lastActivityAt: p.lastActivityAt.map(s), synthesisUpdatedAt: p.synthesisUpdatedAt.map(s),
                synthesisSourceItemID: opt(p.synthesisSourceItemID),
                nameIsAutoGenerated: p.nameIsAutoGenerated, fieldProvenanceJSON: p.fieldProvenanceJSON)
        } ?? []
    }

    private func exportItems(context: ModelContext) -> [ItemExportFull] {
        (try? context.fetch(FetchDescriptor<KnowledgeItem>()))?.compactMap { item in
            var analysis: AnalysisExport?
            if let a = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
                analysis = AnalysisExport(id: sid(a.id), providerId: a.providerId, model: a.model,
                    createdAt: s(a.createdAt), shortSummary: a.shortSummary, detailedSummary: a.detailedSummary,
                    decisions: a.decisions.map { DecisionExport(title: $0.title, details: $0.details, confidence: $0.confidence) },
                    actionItems: a.actionItems.map { ActionItemExport(task: $0.task, owner: $0.owner, dueDate: $0.dueDate.map { ISO8601DateFormatter().string(from: $0) }, confidence: $0.confidence) },
                    risks: a.risks.map { RiskExport(risk: $0.risk, details: $0.details, confidence: $0.confidence) },
                    openQuestions: a.openQuestions.map { QuestionExport(question: $0.question, confidence: $0.confidence) },
                    importantDates: a.importantDates.map { DateExport(date: $0.date, meaning: $0.meaning) },
                    entities: a.entities.map { EntityMentionExport(name: $0.name, type: $0.type.rawValue) })
            }
            var dynAnalysis: DynamicAnalysisExport?
            if let d = try? store.readArtifact(DynamicAnalysis.self, fileName: "analysis.dynamic.json", meetingId: item.id) {
                dynAnalysis = DynamicAnalysisExport(id: sid(d.id), providerId: d.providerId, model: d.model, schemaId: d.schemaId, resultsJSON: nil)
            }
            var transcript: TranscriptExport?
            if let t = try? store.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
                transcript = TranscriptExport(meetingId: t.meetingId.map(sid), languageCode: t.languageCode,
                    sourceEngineId: t.sourceEngineId, createdAt: s(t.createdAt), segmentCount: t.segments.count,
                    segments: t.segments.map { seg in TranscriptSegmentExport(id: sid(seg.id), meetingId: sid(seg.meetingId), speakerId: seg.speakerId.map(sid), text: seg.text, startTime: seg.startTime, endTime: seg.endTime, confidence: seg.confidence) })
            }
            return ItemExportFull(id: sid(item.id), type: item.type.rawValue, title: item.title,
                createdAt: s(item.createdAt), updatedAt: s(item.updatedAt), status: item.status.rawValue,
                tags: item.tags, bodyText: item.bodyText, projectID: opt(item.projectID),
                folderID: opt(item.folderID), isFlagged: item.isFlagged, inboxDate: item.inboxDate.map(s),
                durationSeconds: item.durationSeconds, languageCode: item.languageCode,
                audioFileRelativePath: item.audioFileRelativePath, imageFileRelativePath: item.imageFileRelativePath,
                imagePageCount: item.imagePageCount, transcriptionEngineId: item.transcriptionEngineId,
                analysisProviderId: item.analysisProviderId, calendarEventIdentifier: item.calendarEventIdentifier,
                scheduledDate: item.scheduledDate.map(s), isImported: item.isImported, importSourceURL: item.importSourceURL,
                contextCalendarEventTitle: item.contextCalendarEventTitle, contextPlaceName: item.contextPlaceName,
                contextAudioRoute: item.contextAudioRoute, contextLatitude: item.contextLatitude,
                contextLongitude: item.contextLongitude, contextFocusActive: item.contextFocusActive,
                contextMotionActivity: item.contextMotionActivity, contextBatteryLevel: item.contextBatteryLevel,
                fieldProvenanceJSON: item.fieldProvenanceJSON, analysis: analysis, dynamicAnalysis: dynAnalysis, transcript: transcript)
        } ?? []
    }

    private func exportTasks(context: ModelContext) -> [TaskExportFull] {
        (try? context.fetch(FetchDescriptor<TaskItem>()))?.map { t in
            TaskExportFull(id: sid(t.id), projectID: opt(t.projectID), title: t.title,
                status: t.status.rawValue, priority: t.priority.rawValue, ownerName: t.ownerName,
                dueAt: t.dueAt.map(s), sourceItemID: opt(t.sourceItemID),
                sourceSegmentIDs: t.sourceSegmentIDs, confidence: t.confidence, notes: t.notes,
                createdAt: s(t.createdAt), updatedAt: s(t.updatedAt),
                createdBy: t.createdBy?.rawValue, fieldProvenanceJSON: t.fieldProvenanceJSON)
        } ?? []
    }

    private func exportPeople(context: ModelContext) -> [PersonExport] {
        (try? context.fetch(FetchDescriptor<Person>()))?.map { p in
            PersonExport(id: sid(p.id), displayName: p.displayName, canonicalKey: p.canonicalKey,
                email: p.email, role: p.role, createdAt: s(p.createdAt))
        } ?? []
    }

    private func exportEntities(context: ModelContext) -> [EntityExport] {
        (try? context.fetch(FetchDescriptor<Entity>()))?.map { e in
            EntityExport(id: sid(e.id), kind: e.kind.rawValue, displayName: e.displayName, canonicalKey: e.canonicalKey)
        } ?? []
    }

    private func exportEdges(context: ModelContext) -> [EdgeExportFull] {
        (try? context.fetch(FetchDescriptor<GraphEdge>()))?.map { e in
            EdgeExportFull(id: sid(e.id), fromID: sid(e.fromID), toID: sid(e.toID),
                edgeType: e.edgeType.rawValue, weight: e.weight, provenanceItemID: opt(e.provenanceItemID),
                provenanceSegmentIDs: e.provenanceSegmentIDs, createdAt: s(e.createdAt))
        } ?? []
    }

    private func exportAnnotations(context: ModelContext) -> [AnnotationExport] {
        (try? context.fetch(FetchDescriptor<Annotation>()))?.map { a in
            AnnotationExport(id: sid(a.id), source: a.source, key: a.key, value: a.value,
                itemID: sid(a.itemID), createdAt: s(a.createdAt), confidence: a.confidence)
        } ?? []
    }

    private func exportSignals(context: ModelContext) -> [SignalExport] {
        (try? context.fetch(FetchDescriptor<AgentSuggestion>()))?.map { sig in
            SignalExport(id: sid(sig.id), projectID: opt(sig.projectID), type: sig.type, title: sig.title,
                body: sig.body, status: sig.status, confidence: sig.confidence,
                sourceItemID: opt(sig.sourceItemID), sourceSegmentIDs: sig.sourceSegmentIDs,
                payloadJSON: sig.payloadJSON, createdAt: s(sig.createdAt), resolvedAt: sig.resolvedAt.map({ s($0) }),
                impactScore: sig.impactScore, urgencyScore: sig.urgencyScore, relevanceScore: sig.relevanceScore,
                resolutionReason: sig.resolutionReason, resolvedBy: sig.resolvedByRaw, isCritical: sig.isCritical)
        } ?? []
    }

    private func exportFrames(context: ModelContext) -> [FrameExport] {
        (try? context.fetch(FetchDescriptor<ProjectFrame>()))?.map { f in
            FrameExport(id: sid(f.id), projectID: sid(f.projectID), parentFrameID: opt(f.parentFrameID),
                name: f.name, lensID: f.lensID, filterTags: f.filterTags,
                filterDateStart: f.filterDateStart.map(s), filterDateEnd: f.filterDateEnd.map(s),
                filterItemTypes: f.filterItemTypes, createdAt: s(f.createdAt))
        } ?? []
    }

    private func exportSnapshots(context: ModelContext) -> [SnapshotExport] {
        (try? context.fetch(FetchDescriptor<ProjectSnapshot>()))?.map { snap in
            SnapshotExport(id: sid(snap.id), projectID: sid(snap.projectID), label: snap.label,
                trigger: snap.trigger.rawValue, createdAt: s(snap.createdAt), changeCount: snap.changeCount, summary: snap.summary)
        } ?? []
    }

    private func exportHistory(context: ModelContext) -> [ChangeRecordExport] {
        (try? context.fetch(FetchDescriptor<ChangeRecord>()))?.map { r in
            ChangeRecordExport(id: sid(r.id), entityType: r.entityType, entityID: sid(r.entityID),
                projectID: opt(r.projectID), field: r.field, previousValue: r.previousValue,
                newValue: r.newValue, origin: r.origin.rawValue, timestamp: s(r.timestamp),
                snapshotID: opt(r.snapshotID))
        } ?? []
    }

    private func exportQueue(context: ModelContext) -> [QueueEntryExport] {
        ((try? context.fetch(FetchDescriptor<QueueEntry>())) ?? []).filter { $0.status == .queued || $0.status == .processing }.map { q in
            QueueEntryExport(id: sid(q.id), itemID: sid(q.itemID), projectID: opt(q.projectID),
                status: q.status.rawValue, priority: q.priority, queuedAt: s(q.queuedAt),
                startedAt: q.startedAt.map(s), completedAt: q.completedAt.map(s),
                retryCount: q.retryCount, maxRetries: q.maxRetries, lastError: q.lastError, position: q.position)
        }
    }

    private func exportPrompts() -> [PromptExport] {
        PromptStore.shared.prompts(in: nil).map { p in
            PromptExport(name: p.name, category: p.category, content: p.content,
                description: p.description, variables: p.variables,
                updatedAt: ISO8601DateFormatter().string(from: p.updatedAt), isUserEdited: p.isUserEdited)
        }
    }

    private func exportMemories() -> [MemoryExport] {
        AgentMemoryStore.shared.listAll().map { m in
            MemoryExport(id: m.id.uuidString, pattern: m.pattern, strategy: m.strategy,
                itemType: m.itemType, contentType: m.contentType, language: m.language,
                minDuration: m.minDuration, minChars: m.minChars,
                successCount: m.successCount, failCount: m.failCount,
                lastUsed: ISO8601DateFormatter().string(from: m.lastUsed),
                createdAt: ISO8601DateFormatter().string(from: m.createdAt),
                isStale: m.isStale, relevance: m.relevance)
        }
    }

    private func exportConfig() -> ConfigExport {
        let auto = AutomationSettings.shared
        let activeProviderID = ActiveProviderManager.shared.getActiveProviderID()
        let preferredModel = auto.autoAnalysisModel.isEmpty ? nil : auto.autoAnalysisModel
        return ConfigExport(activeProviderID: activeProviderID, preferredModel: preferredModel,
            autoTranscribe: auto.autoTranscribe, autoAnalyze: auto.autoAnalyze,
            autoAnalysisModel: auto.autoAnalysisModel, autoAnalysisProvider: auto.autoAnalysisProvider)
    }

    // MARK: - SRT Export

    /// Export transcript segments as SubRip (.srt) subtitle format.
    /// Each segment becomes a numbered subtitle block with HH:MM:SS,mmm timestamps.
    func exportSRT(for itemId: UUID) -> String? {
        let store = FileArtifactStore()
        guard let transcript = try? store.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: itemId),
              !transcript.segments.isEmpty else { return nil }

        var srt = ""
        for (index, segment) in transcript.segments.enumerated() {
            let seq = index + 1
            let start = formatSRTTimestamp(segment.startTime)
            let end = formatSRTTimestamp(segment.endTime ?? segment.startTime + 5)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            srt += "\(seq)\n\(start) --> \(end)\n\(text)\n\n"
        }
        return srt.isEmpty ? nil : srt
    }

    private func formatSRTTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - VTT / WebVTT Export

    /// Export transcript segments as WebVTT (.vtt) subtitle format.
    /// Supports speaker labels via `<v Speaker>` tags when speaker info is available.
    func exportVTT(for itemId: UUID) -> String? {
        let store = FileArtifactStore()
        guard let transcript = try? store.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: itemId),
              !transcript.segments.isEmpty else { return nil }

        var vtt = "WEBVTT\n\n"
        // Add a note header
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        vtt += "NOTE\nExported from Wawa Note — \(formatter.string(from: Date()))\n\n"

        for (index, segment) in transcript.segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let start = formatVTTTimestamp(segment.startTime)
            let end = formatVTTTimestamp(segment.endTime ?? segment.startTime + 5)

            // Optional cue identifier
            let cueId = "\(index + 1)"
            vtt += "\(cueId)\n\(start) --> \(end)"

            // Add speaker if available
            if let speakerId = segment.speakerId {
                let shortId = speakerId.uuidString.prefix(6)
                vtt += "\n<v Speaker-\(shortId)>\(text)</v>"
            } else {
                vtt += "\n\(text)"
            }
            vtt += "\n\n"
        }
        return vtt.isEmpty ? nil : vtt
    }

    /// Export as plain WebVTT without cue identifiers or speaker tags.
    func exportVTTSimple(for itemId: UUID) -> String? {
        let store = FileArtifactStore()
        guard let transcript = try? store.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: itemId),
              !transcript.segments.isEmpty else { return nil }

        var vtt = "WEBVTT\n\n"
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = formatVTTTimestamp(segment.startTime)
            let end = formatVTTTimestamp(segment.endTime ?? segment.startTime + 5)
            vtt += "\(start) --> \(end)\n\(text)\n\n"
        }
        return vtt.isEmpty ? nil : vtt
    }

    private func formatVTTTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
