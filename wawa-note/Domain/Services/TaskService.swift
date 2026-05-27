import Foundation
import SwiftData

@MainActor
final class TaskService {
    private let context: ModelContext
    private let edgeService: GraphEdgeService

    init(context: ModelContext, edgeService: GraphEdgeService? = nil) {
        self.context = context
        self.edgeService = edgeService ?? GraphEdgeService(context: context)
    }

    func create(
        title: String,
        projectID: UUID? = nil,
        priority: TaskPriority = .medium,
        ownerName: String? = nil,
        dueAt: Date? = nil,
        sourceItemID: UUID? = nil,
        sourceSegmentIDs: [String] = [],
        confidence: Double? = nil
    ) throws -> TaskItem {
        let task = TaskItem(
            title: title,
            priority: priority,
            ownerName: ownerName,
            dueAt: dueAt,
            sourceItemID: sourceItemID,
            sourceSegmentIDs: sourceSegmentIDs,
            confidence: confidence
        )
        task.projectID = projectID
        context.insert(task)
        try context.save()

        if let source = sourceItemID {
            try edgeService.create(fromID: source, toID: task.id, edgeType: .produced,
                                   provenanceItemID: source, provenanceSegmentIDs: sourceSegmentIDs)
        }
        if let projectID {
            try edgeService.create(fromID: task.id, toID: projectID, edgeType: .belongsTo)
        }

        return task
    }

    func fetch(id: UUID) throws -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func tasks(for projectID: UUID) throws -> [TaskItem] {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.projectID == projectID })
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func tasksByStatus(_ status: TaskStatus) throws -> [TaskItem] {
        let raw = status.rawValue
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.statusRaw == raw })
        descriptor.sortBy = [SortDescriptor(\.dueAt, order: .forward)]
        return try context.fetch(descriptor)
    }

    func tasksForOwner(_ name: String) throws -> [TaskItem] {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.ownerName == name })
        descriptor.sortBy = [SortDescriptor(\.dueAt, order: .forward)]
        return try context.fetch(descriptor)
    }

    func updateStatus(_ task: TaskItem, to status: TaskStatus) throws {
        task.status = status
        task.updatedAt = Date()
        try context.save()
    }

    func deleteTask(_ task: TaskItem) throws {
        // Remove associated edges
        let tid = task.id
        let outgoing = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == tid }))
        for edge in outgoing { context.delete(edge) }
        let incoming = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == tid }))
        for edge in incoming { context.delete(edge) }
        context.delete(task)
        try context.save()
    }
}
