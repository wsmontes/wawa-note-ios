import SwiftUI
import SwiftData
// Related JIRA: KAN-12, KAN-64


struct ProjectExportActions {
    let project: Project
    let modelContext: ModelContext
    let services: ServiceContainer

    func exportMarkdown() {
        let items = (try? services.projects.items(in: project.id)) ?? []
        let derivedTasks = (try? services.derived.fetch(for: project.id, type: .task)) ?? []
        let edges = (try? GraphEdgeService(context: modelContext).neighborhood(of: project.id, radius: 2)) ?? []
        let exporter = ProjectExportService()

        let taskRows = derivedTasks.map { t -> String in
            let check = t.status == .done ? "x" : " "
            var line = "- [\(check)] **\(t.title)**"
            if let owner = t.ownerName { line += " — \(owner)" }
            if let prio = t.priorityRaw, prio != "medium" { line += " · \(prio.capitalized)" }
            if let due = t.dueAt { line += " · Due: \(due.formatted(date: .abbreviated, time: .omitted))" }
            return line
        }

        let md = exporter.exportMarkdown(project: project, items: items, tasks: taskRows, edges: edges)
        let vc = UIActivityViewController(activityItems: [md], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController { root.present(vc, animated: true) }
    }

    func exportJSON() {
        let svc = InstanceExportService()
        let export = svc.exportSingleProject(project, context: modelContext)
        guard let data = try? JSONEncoder().encode(export),
              let json = String(data: data, encoding: .utf8) else { return }
        let vc = UIActivityViewController(activityItems: [json], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController { root.present(vc, animated: true) }
    }
}
