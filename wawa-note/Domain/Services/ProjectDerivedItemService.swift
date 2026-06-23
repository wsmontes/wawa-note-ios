import Foundation
import SwiftData
// Related JIRA: KAN-8, KAN-38


@MainActor
final class ProjectDerivedItemService {
    private let context: ModelContext
    private let edgeService: GraphEdgeService

    init(context: ModelContext, edgeService: GraphEdgeService? = nil) {
        self.context = context
        self.edgeService = edgeService ?? GraphEdgeService(context: context)
    }

    // MARK: - Create

    func createTask(
        title: String,
        projectID: UUID,
        sourceItemID: UUID? = nil,
        priority: TaskPriority = .medium,
        ownerName: String? = nil,
        dueAt: Date? = nil,
        bodyJSON: String? = nil
    ) throws -> ProjectDerivedItem {
        // KAN-75: Dedup — skip if task with same title already exists in project
        let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespaces)
        let typeRaw = ProjectDerivedType.task.rawValue
        let existing = try context.fetch(FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate { $0.projectID == projectID && $0.typeRaw == typeRaw }
        ))
        if existing.contains(where: { $0.title.lowercased().trimmingCharacters(in: .whitespaces) == normalizedTitle }) {
            AppLog.general.info("ProjectDerivedItemService: dedup — task '\(title)' already exists in project")
            return existing.first { $0.title.lowercased().trimmingCharacters(in: .whitespaces) == normalizedTitle }!
        }

        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: sourceItemID,
            type: .task,
            title: title,
            bodyJSON: bodyJSON,
            status: .todo,
            priority: priority,
            ownerName: ownerName,
            dueAt: dueAt
        )
        context.insert(item)
        try context.save()
        // Create edge linking task to project
        try edgeService.create(fromID: item.id, toID: projectID, edgeType: .belongsTo)
        if let source = sourceItemID {
            try edgeService.create(fromID: source, toID: item.id, edgeType: .produced)
        }
        return item
    }

    func createSignal(
        title: String,
        projectID: UUID,
        sourceItemID: UUID? = nil,
        signalBody: SignalBody,
        confidence: Double? = nil,
        isCritical: Bool = false
    ) throws -> ProjectDerivedItem {
        // KAN-75: Dedup — skip if signal with same title already active in project
        let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespaces)
        let typeRaw = ProjectDerivedType.signal.rawValue
        let existing = try context.fetch(FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate { $0.projectID == projectID && $0.typeRaw == typeRaw }
        ))
        if let dup = existing.first(where: { $0.title.lowercased().trimmingCharacters(in: .whitespaces) == normalizedTitle }) {
            AppLog.general.info("ProjectDerivedItemService: dedup — signal '\(title)' already active in project")
            return dup
        }

        let bodyData = try? JSONEncoder().encode(signalBody)
        let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: sourceItemID,
            type: .signal,
            title: title,
            bodyJSON: bodyStr,
            status: .visible,
            confidence: confidence,
            isCritical: isCritical
        )
        context.insert(item)
        try context.save()
        if let source = sourceItemID {
            try edgeService.create(fromID: source, toID: item.id, edgeType: .produced)
        }
        return item
    }

    func createSynthesis(
        projectID: UUID,
        markdown: String,
        sections: [SynthesisSection],
        metrics: [SynthesisMetric],
        updatedFromItemIDs: [UUID]
    ) throws -> ProjectDerivedItem {
        let body = SynthesisBody(
            markdown: markdown,
            sections: sections,
            metrics: metrics,
            updatedFromItemIDs: updatedFromItemIDs,
            generatedAt: Date()
        )
        let bodyData = try? JSONEncoder().encode(body)
        let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

        // Upsert: delete existing synthesis, create new
        if let existing = try? fetchSynthesis(for: projectID).first {
            try delete(existing)
        }

        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: nil, // synthesis belongs to project, not any single item
            type: .synthesis,
            title: "Project Synthesis",
            bodyJSON: bodyStr
        )
        context.insert(item)
        try context.save()
        return item
    }

    func createConnection(
        title: String,
        projectID: UUID,
        fromDerivedID: UUID,
        toDerivedID: UUID,
        edgeType: EdgeType,
        provenanceItemID: UUID? = nil
    ) throws -> ProjectDerivedItem {
        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: provenanceItemID,
            type: .connection,
            title: title,
            status: nil
        )
        context.insert(item)
        // Create the actual GraphEdge alongside the derived item
        try edgeService.create(
            fromID: fromDerivedID,
            toID: toDerivedID,
            edgeType: edgeType,
            provenanceItemID: provenanceItemID
        )
        try context.save()
        return item
    }

    // MARK: - Read

    func fetch(id: UUID) throws -> ProjectDerivedItem? {
        var descriptor = FetchDescriptor<ProjectDerivedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetch(for projectID: UUID) throws -> [ProjectDerivedItem] {
        var descriptor = FetchDescriptor<ProjectDerivedItem>(predicate: #Predicate { $0.projectID == projectID })
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func fetch(for projectID: UUID, type: ProjectDerivedType) throws -> [ProjectDerivedItem] {
        let typeRaw = type.rawValue
        var descriptor = FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate { $0.projectID == projectID && $0.typeRaw == typeRaw }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func fetchSynthesis(for projectID: UUID) throws -> [ProjectDerivedItem] {
        try fetch(for: projectID, type: .synthesis)
    }

    func fetchActiveTasks(for projectID: UUID) throws -> [ProjectDerivedItem] {
        let typeRaw = ProjectDerivedType.task.rawValue
        let todoRaw = ProjectDerivedStatus.todo.rawValue
        let inProgressRaw = ProjectDerivedStatus.inProgress.rawValue
        var descriptor = FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate {
                $0.projectID == projectID && $0.typeRaw == typeRaw &&
                ($0.statusRaw == todoRaw || $0.statusRaw == inProgressRaw)
            }
        )
        descriptor.sortBy = [SortDescriptor(\.dueAt, order: .forward)]
        return try context.fetch(descriptor)
    }

    func fetchActiveSignals(for projectID: UUID) throws -> [ProjectDerivedItem] {
        let typeRaw = ProjectDerivedType.signal.rawValue
        let visibleRaw = ProjectDerivedStatus.visible.rawValue
        let ackRaw = ProjectDerivedStatus.acknowledged.rawValue
        var descriptor = FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate {
                $0.projectID == projectID && $0.typeRaw == typeRaw &&
                ($0.statusRaw == visibleRaw || $0.statusRaw == ackRaw)
            }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    // MARK: - Update

    func updateStatus(_ item: ProjectDerivedItem, to status: ProjectDerivedStatus) throws {
        item.statusRaw = status.rawValue
        item.updatedAt = Date()
        if status == .done || status == .cancelled || status == .resolved || status == .dismissed {
            item.resolvedAt = Date()
        }
        try context.save()
    }

    func updateTask(
        _ item: ProjectDerivedItem,
        title: String? = nil,
        ownerName: String? = nil,
        priority: TaskPriority? = nil,
        dueAt: Date? = nil
    ) throws {
        guard item.type == .task else { return }
        if let t = title { item.title = t }
        if let o = ownerName { item.ownerName = o }
        if let p = priority { item.priorityRaw = p.rawValue }
        if let d = dueAt { item.dueAt = d }
        item.updatedAt = Date()
        try context.save()
    }

    func acknowledgeSignal(_ item: ProjectDerivedItem) throws {
        guard item.type == .signal else { return }
        try updateStatus(item, to: .acknowledged)
    }

    func resolveSignal(_ item: ProjectDerivedItem, reason: String) throws {
        guard item.type == .signal else { return }
        item.resolutionReason = reason
        try updateStatus(item, to: .resolved)
    }

    // MARK: - Delete

    func delete(_ item: ProjectDerivedItem) throws {
        // Remove associated edges
        let iid = item.id
        let outgoing = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == iid }))
        for edge in outgoing { context.delete(edge) }
        let incoming = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == iid }))
        for edge in incoming { context.delete(edge) }
        context.delete(item)
        try context.save()
    }

    // MARK: - Reprocess marking

    /// Marks all source items in a project as needing reprocessing with the given context.
    /// Used when project domain changes or user requests re-analysis.
    /// Marks items for reprocessing. Delegates to ProjectService which sets the
    /// needsProjectReprocessing flag on KnowledgeItem records.
    func markItemsForReprocessing(projectID: UUID, context reprocessContext: String, itemIDs: [UUID]) {
        let projectSvc = ProjectService(context: self.context)
        for itemID in itemIDs {
            do {
                try projectSvc.markForReprocessing(itemID: itemID, projectID: projectID, context: reprocessContext)
            } catch {
                AppLog.general.error("ProjectDerivedItemService: failed to mark item \(itemID) for reprocessing: \(error)")
            }
        }
    }

    // Protocol conformance helpers
    func deleteTask(_ item: ProjectDerivedItem) throws { try delete(item) }
    func tasks(for projectID: UUID) throws -> [ProjectDerivedItem] { try fetch(for: projectID, type: .task) }
}
