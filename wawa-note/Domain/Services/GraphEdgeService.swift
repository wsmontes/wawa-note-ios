import Foundation
import SwiftData

@MainActor
final class GraphEdgeService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func create(
        fromID: UUID,
        toID: UUID,
        edgeType: EdgeType,
        weight: Double = 1.0,
        provenanceItemID: UUID? = nil,
        provenanceSegmentIDs: [String] = []
    ) throws -> GraphEdge {
        // Avoid duplicates
        let existing = try find(fromID: fromID, toID: toID, edgeType: edgeType)
        if let existing {
            existing.weight = max(existing.weight, weight)
            try context.save()
            return existing
        }

        let edge = GraphEdge(
            fromID: fromID,
            toID: toID,
            edgeType: edgeType,
            weight: weight,
            provenanceItemID: provenanceItemID,
            provenanceSegmentIDs: provenanceSegmentIDs
        )
        context.insert(edge)
        try context.save()
        return edge
    }

    func find(fromID: UUID, toID: UUID, edgeType: EdgeType) throws -> GraphEdge? {
        let typeRaw = edgeType.rawValue
        var descriptor = FetchDescriptor<GraphEdge>(
            predicate: #Predicate { $0.fromID == fromID && $0.toID == toID && $0.edgeTypeRaw == typeRaw }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func edges(from nodeID: UUID) throws -> [GraphEdge] {
        var descriptor = FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == nodeID })
        descriptor.sortBy = [SortDescriptor(\.weight, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func edges(to nodeID: UUID) throws -> [GraphEdge] {
        var descriptor = FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == nodeID })
        descriptor.sortBy = [SortDescriptor(\.weight, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func neighborhood(of nodeID: UUID, radius: Int = 1) throws -> [GraphEdge] {
        var allEdges: [GraphEdge] = []
        var visited: Set<UUID> = [nodeID]
        var frontier: Set<UUID> = [nodeID]

        for _ in 0..<radius {
            var nextFrontier: Set<UUID> = []
            for node in frontier {
                let outgoing = try edges(from: node)
                let incoming = try edges(to: node)
                allEdges.append(contentsOf: outgoing)
                allEdges.append(contentsOf: incoming)
                for edge in outgoing { if !visited.contains(edge.toID) { nextFrontier.insert(edge.toID) } }
                for edge in incoming { if !visited.contains(edge.fromID) { nextFrontier.insert(edge.fromID) } }
            }
            visited.formUnion(nextFrontier)
            frontier = nextFrontier
        }
        return allEdges
    }

    func edges(ofType edgeType: EdgeType) throws -> [GraphEdge] {
        let typeRaw = edgeType.rawValue
        var descriptor = FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.edgeTypeRaw == typeRaw })
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// Increase weight on the strongest edge between two nodes (any type).
    /// Used to persist edge reinforcements from project ingestion.
    func reinforce(fromID: UUID, toID: UUID) throws {
        // Find all edges between these nodes, reinforce the one with highest weight
        let fromTypeRaw = EdgeType.relatesTo.rawValue
        var descriptor = FetchDescriptor<GraphEdge>(
            predicate: #Predicate { $0.fromID == fromID && $0.toID == toID }
        )
        descriptor.sortBy = [SortDescriptor(\.weight, order: .reverse)]
        descriptor.fetchLimit = 1
        if let edge = try context.fetch(descriptor).first {
            edge.weight += 0.5
            try context.save()
        }
    }

    func deleteEdge(_ edge: GraphEdge) throws {
        context.delete(edge)
        try context.save()
    }

    func recentEdges(limit: Int = 20) throws -> [GraphEdge] {
        var descriptor = FetchDescriptor<GraphEdge>()
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }
}
