import Foundation
import SwiftData
import OSLog

@MainActor
final class EntityExtractionService {
    private let context: ModelContext
    private let entityService: EntityService
    private let edgeService: GraphEdgeService

    init(context: ModelContext, entityService: EntityService? = nil, edgeService: GraphEdgeService? = nil) {
        self.context = context
        self.entityService = entityService ?? EntityService(context: context)
        self.edgeService = edgeService ?? GraphEdgeService(context: context)
    }

    /// Extract entities from MeetingAnalysis and persist as Entity + GraphEdge (mentions).
    /// Returns the created/updated entities.
    func extractAndPersist(from analysis: MeetingAnalysis, sourceItemID: UUID) throws -> [Entity] {
        var persisted: [Entity] = []

        for mention in analysis.entities {
            let kind = mapEntityKind(mention.type)
            let entity = try entityService.findOrCreate(kind: kind, displayName: mention.name)

            // Edge: sourceItem mentions entity
            try edgeService.create(
                fromID: sourceItemID,
                toID: entity.id,
                edgeType: .mentions,
                weight: 1.0,
                provenanceItemID: sourceItemID,
                provenanceSegmentIDs: mention.sourceSegmentIds.map(\.uuidString)
            )

            persisted.append(entity)
        }

        // Also extract decisions as entities with edges
        for decision in analysis.decisions {
            // Edge: sourceItem produced decision
            let decisionEntity = try entityService.findOrCreate(kind: .other, displayName: "Decision: \(decision.title)")
            try edgeService.create(
                fromID: sourceItemID,
                toID: decisionEntity.id,
                edgeType: .produced,
                weight: decision.confidence ?? 1.0,
                provenanceItemID: sourceItemID,
                provenanceSegmentIDs: decision.sourceSegmentIds.map(\.uuidString)
            )
            persisted.append(decisionEntity)
        }

        AppLog.general.info("EntityExtraction: persisted \(persisted.count) entities from item \(sourceItemID)")
        return persisted
    }

    /// Create GraphEdges connecting decisions to their supporting evidence.
    func buildDecisionGraph(from analysis: MeetingAnalysis, sourceItemID: UUID) throws {
        var createdTaskIDs: [UUID] = []

        // Action items → tasks with provenance
        for action in analysis.actionItems {
            if let task = try? findOrCreateTask(from: action, sourceItemID: sourceItemID) {
                try edgeService.create(
                    fromID: sourceItemID,
                    toID: task.id,
                    edgeType: .produced,
                    weight: action.confidence ?? 1.0,
                    provenanceItemID: sourceItemID,
                    provenanceSegmentIDs: action.sourceSegmentIds.map(\.uuidString)
                )
                createdTaskIDs.append(task.id)
            }
        }

        // Decisions → sourceItem (supported_by) edges
        for decision in analysis.decisions {
            if !decision.sourceSegmentIds.isEmpty {
                let decisionEntity = try entityService.findOrCreate(kind: .other, displayName: "Decision: \(decision.title)")
                try edgeService.create(
                    fromID: decisionEntity.id,
                    toID: sourceItemID,
                    edgeType: .supports,
                    weight: decision.confidence ?? 1.0,
                    provenanceItemID: sourceItemID,
                    provenanceSegmentIDs: decision.sourceSegmentIds.map(\.uuidString)
                )
            }

            // Decision → precedes → first task (temporal link)
            if let firstTask = createdTaskIDs.first {
                let decisionEntity = try entityService.findOrCreate(kind: .other, displayName: "Decision: \(decision.title)")
                try edgeService.create(
                    fromID: decisionEntity.id,
                    toID: firstTask,
                    edgeType: .precedes,
                    weight: decision.confidence ?? 1.0,
                    provenanceItemID: sourceItemID,
                    provenanceSegmentIDs: decision.sourceSegmentIds.map(\.uuidString)
                )
            }
        }
    }

    private func findOrCreateTask(from action: ActionItem, sourceItemID: UUID) throws -> TaskItem? {
        guard !action.task.isEmpty else { return nil }

        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.title == action.task && $0.sourceItemID == sourceItemID }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let task = TaskItem(
            title: action.task,
            status: .todo,
            priority: .medium,
            ownerName: action.owner,
            dueAt: action.dueDate,
            sourceItemID: sourceItemID,
            sourceSegmentIDs: action.sourceSegmentIds.map(\.uuidString),
            confidence: action.confidence
        )
        context.insert(task)
        try context.save()
        return task
    }

    private func mapEntityKind(_ type: EntityType) -> EntityKind {
        switch type {
        case .person: return .person
        case .organization: return .organization
        case .system, .tool: return .system
        case .repository: return .repository
        case .location: return .location
        case .project, .other: return .other
        }
    }
}
