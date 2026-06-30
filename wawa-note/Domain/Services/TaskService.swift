import Foundation
import SwiftData
import WawaNoteCore

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
    confidence: Double? = nil,
    createdBy: FieldOrigin = .user
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
    task.createdBy = createdBy
    // Mark initial field provenance
    var prov = FieldProvenance.empty
    let origin = createdBy
    prov.mark(field: "title", origin: origin)
    prov.mark(field: "status", origin: origin)
    prov.mark(field: "priority", origin: origin)
    if ownerName != nil { prov.mark(field: "ownerName", origin: origin) }
    if dueAt != nil { prov.mark(field: "dueAt", origin: origin) }
    task.fieldProvenanceJSON = prov.encode()
    context.insert(task)
    try context.save()

    if let source = sourceItemID {
      try edgeService.create(
        fromID: source, toID: task.id, edgeType: .produced,
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
    let prev = task.status.rawValue
    task.status = status
    task.updatedAt = Date()
    try context.save()
    VersioningService.shared.recordChange(
      entityType: "TaskItem", entityID: task.id, projectID: task.projectID,
      field: "status", previousValue: prev, newValue: status.rawValue, origin: .user,
      context: context)
  }

  func updateTask(
    _ task: TaskItem,
    title: String? = nil,
    ownerName: String? = nil,
    priority: TaskPriority? = nil,
    dueAt: Date? = nil
  ) throws {
    let vs = VersioningService.shared
    let ctx = context
    let pid = task.projectID
    let tid = task.id
    if let title {
      let prev = task.title
      task.title = title
      vs.recordChange(
        entityType: "TaskItem", entityID: tid, projectID: pid, field: "title", previousValue: prev,
        newValue: title, origin: .user, context: ctx)
    }
    if let ownerName {
      let prev = task.ownerName
      task.ownerName = ownerName
      vs.recordChange(
        entityType: "TaskItem", entityID: tid, projectID: pid, field: "ownerName",
        previousValue: prev, newValue: ownerName, origin: .user, context: ctx)
    }
    if let priority {
      let prev = task.priority.rawValue
      task.priority = priority
      vs.recordChange(
        entityType: "TaskItem", entityID: tid, projectID: pid, field: "priority",
        previousValue: prev, newValue: priority.rawValue, origin: .user, context: ctx)
    }
    if let dueAt {
      let prev = task.dueAt?.ISO8601Format()
      task.dueAt = dueAt
      vs.recordChange(
        entityType: "TaskItem", entityID: tid, projectID: pid, field: "dueAt", previousValue: prev,
        newValue: dueAt.ISO8601Format(), origin: .user, context: ctx)
    }
    task.updatedAt = Date()
    try context.save()
  }

  func deleteTask(_ task: TaskItem) throws {
    // Remove associated edges
    let tid = task.id
    let outgoing = try context.fetch(
      FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == tid }))
    for edge in outgoing { context.delete(edge) }
    let incoming = try context.fetch(
      FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == tid }))
    for edge in incoming { context.delete(edge) }
    context.delete(task)
    try context.save()
  }
}
