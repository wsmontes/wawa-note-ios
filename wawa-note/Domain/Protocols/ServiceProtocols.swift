import Foundation
import SwiftData
// Related JIRA: KAN-11, KAN-56


// MARK: - ProjectServiceProtocol

@MainActor
protocol ProjectServiceProtocol: AnyObject {
    func create(name: String, summary: String?, iconName: String?) throws -> Project
    func fetch(id: UUID) throws -> Project?
    func allProjects() throws -> [Project]
    func activeProjects() throws -> [Project]
    func items(in projectID: UUID) throws -> [KnowledgeItem]
    func addItem(_ itemID: UUID, to projectID: UUID) throws
    func removeItem(_ itemID: UUID) throws
    func deleteProject(_ project: Project) throws
    func setColor(_ projectID: UUID, hex: String) throws
    func derivedItems(in projectID: UUID) throws -> [ProjectDerivedItem]
    func totalContentCount(for projectID: UUID) throws -> Int
}

// MARK: - KnowledgeItemServiceProtocol

@MainActor
protocol KnowledgeItemServiceProtocol: AnyObject {
    func createItem(type: KnowledgeItemType, title: String, bodyText: String?, folderID: UUID?, durationSeconds: Double?, languageCode: String?, tags: [String], inboxDate: Date?) throws -> KnowledgeItem
    func fetchItem(id: UUID) throws -> KnowledgeItem?
    func allItems() throws -> [KnowledgeItem]
}

// MARK: - ProjectDerivedItemServiceProtocol

@MainActor
protocol ProjectDerivedItemServiceProtocol: AnyObject {
    func createTask(title: String, projectID: UUID, sourceItemID: UUID?, priority: TaskPriority, ownerName: String?, dueAt: Date?, bodyJSON: String?) throws -> ProjectDerivedItem
    func createSignal(title: String, projectID: UUID, sourceItemID: UUID?, signalBody: SignalBody, confidence: Double?, isCritical: Bool) throws -> ProjectDerivedItem
    func createSynthesis(projectID: UUID, markdown: String, sections: [SynthesisSection], metrics: [SynthesisMetric], updatedFromItemIDs: [UUID]) throws -> ProjectDerivedItem
    func fetch(id: UUID) throws -> ProjectDerivedItem?
    func fetch(for projectID: UUID) throws -> [ProjectDerivedItem]
    func fetch(for projectID: UUID, type: ProjectDerivedType) throws -> [ProjectDerivedItem]
    func fetchActiveTasks(for projectID: UUID) throws -> [ProjectDerivedItem]
    func fetchActiveSignals(for projectID: UUID) throws -> [ProjectDerivedItem]
    func updateStatus(_ item: ProjectDerivedItem, to status: ProjectDerivedStatus) throws
    func updateTask(_ item: ProjectDerivedItem, title: String?, ownerName: String?, priority: TaskPriority?, dueAt: Date?) throws
    func delete(_ item: ProjectDerivedItem) throws
}

// MARK: - GraphEdgeServiceProtocol

@MainActor
protocol GraphEdgeServiceProtocol: AnyObject {
    @discardableResult
    func create(fromID: UUID, toID: UUID, edgeType: EdgeType, weight: Double, provenanceItemID: UUID?, provenanceSegmentIDs: [String]) throws -> GraphEdge
    func find(fromID: UUID, toID: UUID, edgeType: EdgeType) throws -> GraphEdge?
    func edges(from nodeID: UUID) throws -> [GraphEdge]
    func edges(to nodeID: UUID) throws -> [GraphEdge]
    func neighborhood(of nodeID: UUID, radius: Int) throws -> [GraphEdge]
}

extension GraphEdgeServiceProtocol {
    @discardableResult
    func create(fromID: UUID, toID: UUID, edgeType: EdgeType, weight: Double = 1.0, provenanceItemID: UUID? = nil, provenanceSegmentIDs: [String] = []) throws -> GraphEdge {
        try create(fromID: fromID, toID: toID, edgeType: edgeType, weight: weight, provenanceItemID: provenanceItemID, provenanceSegmentIDs: provenanceSegmentIDs)
    }
}

// MARK: - PersonServiceProtocol

@MainActor
protocol PersonServiceProtocol: AnyObject {
    func findOrCreate(displayName: String, email: String?, role: String?) throws -> Person
    func fetch(id: UUID) throws -> Person?
    func all() throws -> [Person]
    func search(_ query: String) throws -> [Person]
}

// MARK: - EntityServiceProtocol

@MainActor
protocol EntityServiceProtocol: AnyObject {
    func findOrCreate(kind: EntityKind, displayName: String) throws -> Entity
    func fetch(id: UUID) throws -> Entity?
    func all(kind: EntityKind?) throws -> [Entity]
    func search(_ query: String) throws -> [Entity]
}
