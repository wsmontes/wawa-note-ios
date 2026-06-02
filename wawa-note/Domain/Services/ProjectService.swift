import Foundation
import SwiftData

@MainActor
final class ProjectService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func create(name: String, summary: String? = nil, iconName: String? = nil) throws -> Project {
        let project = Project(name: name, summary: summary, colorHex: assignColor(), iconName: iconName)
        context.insert(project)
        try context.save()
        return project
    }

    func setColor(_ projectID: UUID, hex: String) throws {
        guard let project = try fetch(id: projectID) else { return }
        project.colorHex = hex
        try context.save()
    }

    func colorsForItems(_ items: [KnowledgeItem]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        let projectIDs = Set(items.compactMap(\.projectID))
        for pid in projectIDs {
            if let project = try? fetch(id: pid), let hex = project.colorHex {
                result[pid] = hex
            }
        }
        return result
    }

    // MARK: - Private

    private func assignColor() -> String {
        let active = (try? activeProjects()) ?? []
        var usage: [String: Int] = [:]
        for hex in ProjectPalette.allHexes { usage[hex] = 0 }
        for p in active {
            if let hex = p.colorHex { usage[hex, default: 0] += 1 }
        }
        return ProjectPalette.allHexes.min(by: { usage[$0]! < usage[$1]! }) ?? ProjectPalette.allHexes[0]
    }

    func fetch(id: UUID) throws -> Project? {
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func allProjects() throws -> [Project] {
        var descriptor = FetchDescriptor<Project>()
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func activeProjects() throws -> [Project] {
        let active = ProjectStatus.active.rawValue
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.statusRaw == active })
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func items(in projectID: UUID) throws -> [KnowledgeItem] {
        var descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.projectID == projectID })
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// Assign an item to a project. Persists immediately.
    /// Pipeline must be started separately by the caller.
    func addItem(_ itemID: UUID, to projectID: UUID) throws {
        guard let item = try fetchItem(itemID) else {
            AppLog.provider.error("ProjectService.addItem: item \(itemID) not found in store")
            return
        }
        item.projectID = projectID
        item.updatedAt = Date()
        if item.inboxDate != nil {
            item.inboxDate = nil
        }
        try context.save()
        AppLog.provider.info("ProjectService.addItem: \(item.title) -> project \(projectID)")
    }

    func removeItem(_ itemID: UUID) throws {
        guard let item = try fetchItem(itemID) else { return }
        item.projectID = nil
        item.updatedAt = Date()
        try context.save()
    }

    func deleteProject(_ project: Project) throws {
        let items = try self.items(in: project.id)
        for item in items {
            item.projectID = nil
            item.updatedAt = Date()
        }
        let projectId: UUID? = project.id
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.projectID == projectId }))
        for task in tasks { context.delete(task) }
        let pid = project.id
        let edgesOut = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == pid }))
        for edge in edgesOut { context.delete(edge) }
        let edgesIn = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == pid }))
        for edge in edgesIn { context.delete(edge) }
        context.delete(project)
        try context.save()
    }

    private func fetchItem(_ id: UUID) throws -> KnowledgeItem? {
        var descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
