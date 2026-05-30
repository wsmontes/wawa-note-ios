import Foundation
import SwiftData

@MainActor
final class ProjectService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func create(name: String, summary: String? = nil, iconName: String? = nil) throws -> Project {
        let project = Project(name: name, summary: summary, iconName: iconName)
        context.insert(project)
        try context.save()
        return project
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

    /// Standardized entry point for adding any item to a project.
    /// Handles: projectID assignment, inbox removal, timestamp, persistence,
    /// state tracking, and background pipeline (transcription → analysis → ingestion).
    /// - Parameters:
    ///   - startPipeline: Set to false only when downstream work must complete first
    ///     (e.g. audio file storage) and the caller will start the pipeline manually.
    func addItem(_ itemID: UUID, to projectID: UUID, startPipeline: Bool = true) throws {
        guard let item = try fetchItem(itemID) else { return }
        item.projectID = projectID
        item.updatedAt = Date()
        if item.inboxDate != nil {
            item.inboxDate = nil
        }
        try context.save()
        ProjectIngestionState.shared.start(projectID)
        if startPipeline {
            ContentPipelineService.shared.process( itemID, using: context)
        }
    }

    func removeItem(_ itemID: UUID) throws {
        guard let item = try fetchItem(itemID) else { return }
        let previousProjectID = item.projectID
        item.projectID = nil
        item.updatedAt = Date()
        try context.save()
        if let pid = previousProjectID {
            ProjectIngestionState.shared.finish(pid)
        }
    }

    func deleteProject(_ project: Project) throws {
        // Unlink items
        let items = try self.items(in: project.id)
        for item in items {
            item.projectID = nil
            item.updatedAt = Date()
        }
        // Delete associated tasks
        let projectId: UUID? = project.id
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.projectID == projectId }))
        for task in tasks { context.delete(task) }
        // Delete edges pointing to/from project
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
