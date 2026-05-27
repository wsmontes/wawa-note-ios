import Foundation
import SwiftData

struct ProjectExportService {
    private let fileStore = FileArtifactStore()

    // MARK: - Project Markdown export

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
