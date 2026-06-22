import Foundation
import SwiftData

/// TaskService is now a thin facade over ProjectDerivedItemService.
/// It exists for backward compatibility during the migration period.
/// New code should use ProjectDerivedItemService directly.
@available(*, deprecated, message: "Use ProjectDerivedItemService directly")
@MainActor
final class TaskService {
    private let context: ModelContext
    private let derivedService: ProjectDerivedItemService

    init(context: ModelContext, edgeService: GraphEdgeService? = nil) {
        self.context = context
        let edges = edgeService ?? GraphEdgeService(context: context)
        self.derivedService = ProjectDerivedItemService(context: context, edgeService: edges)
    }

    /// Creates a task as a ProjectDerivedItem. Returns a TaskItem shim for legacy callers.
    func create(
        title: String,
        projectID: UUID? = nil,
        priority: TaskPriority = .medium,
        ownerName: String? = nil,
        dueAt: Date? = nil,
        sourceItemID: UUID? = nil,
        sourceSegmentIDs: [String] = [],
        confidence: Double? = nil,
        createdBy: FieldOrigin = .user
    ) throws -> TaskItem {
        guard let projectID else {
            // Tasks without a project go into a legacy TaskItem (orphaned tasks)
            let task = TaskItem(title: title, priority: priority, ownerName: ownerName, dueAt: dueAt, sourceItemID: sourceItemID, sourceSegmentIDs: sourceSegmentIDs, confidence: confidence)
            task.createdBy = createdBy
            context.insert(task)
            try context.save()
            return task
        }

        let body = TaskBody(description: nil, sourceSegmentIDs: sourceSegmentIDs.isEmpty ? nil : sourceSegmentIDs, aiGenerated: createdBy != .user, suggestedByItemID: sourceItemID)
        let bodyData = try? JSONEncoder().encode(body)
        let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

        let derived = try derivedService.createTask(
            title: title,
            projectID: projectID,
            sourceItemID: sourceItemID,
            priority: priority,
            ownerName: ownerName,
            dueAt: dueAt,
            bodyJSON: bodyStr
        )

        // Return a shim TaskItem for legacy callers that expect the old type
        let task = TaskItem(id: derived.id, title: title, priority: priority, ownerName: ownerName, dueAt: dueAt, sourceItemID: sourceItemID, sourceSegmentIDs: sourceSegmentIDs, confidence: confidence)
        task.projectID = projectID
        task.createdBy = createdBy
        return task
    }

    /// Fetches tasks for a project as ProjectDerivedItem, returns as TaskItem shims.
    func tasks(for projectID: UUID) throws -> [TaskItem] {
        let derived = try derivedService.fetch(for: projectID, type: .task)
        return derived.map { d in
            let task = TaskItem(id: d.id, title: d.title, priority: TaskPriority(rawValue: d.priorityRaw ?? "medium") ?? .medium, ownerName: d.ownerName, dueAt: d.dueAt)
            task.projectID = d.projectID
            if let statusRaw = d.statusRaw {
                task.statusRaw = statusRaw
            }
            return task
        }
    }

    func fetch(id: UUID) throws -> TaskItem? {
        guard let d = try derivedService.fetch(id: id), d.type == .task else { return nil }
        let task = TaskItem(id: d.id, title: d.title, priority: TaskPriority(rawValue: d.priorityRaw ?? "medium") ?? .medium, ownerName: d.ownerName, dueAt: d.dueAt)
        task.projectID = d.projectID
        if let statusRaw = d.statusRaw { task.statusRaw = statusRaw }
        return task
    }

    func updateStatus(_ task: TaskItem, to status: TaskStatus) throws {
        guard let d = try derivedService.fetch(id: task.id) else { return }
        let derivedStatus: ProjectDerivedStatus = {
            switch status {
            case .todo: return .todo
            case .inProgress: return .inProgress
            case .done: return .done
            case .cancelled: return .cancelled
            }
        }()
        try derivedService.updateStatus(d, to: derivedStatus)
    }

    func deleteTask(_ task: TaskItem) throws {
        guard let d = try derivedService.fetch(id: task.id) else { return }
        try derivedService.delete(d)
    }
}
