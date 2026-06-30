import Foundation

@testable import Wawa_Note

// MARK: - MockProjectService

@MainActor
final class MockProjectService: ProjectServiceProtocol {
    var projects: [Project] = []
    var itemsByProject: [UUID: [KnowledgeItem]] = [:]
    var createCallCount = 0

    func create(name: String, summary: String?, iconName: String?) throws -> Project {
        createCallCount += 1
        let p = Project(name: name, summary: summary, iconName: iconName)
        projects.append(p)
        return p
    }

    func fetch(id: UUID) throws -> Project? {
        projects.first { $0.id == id }
    }

    func allProjects() throws -> [Project] { projects }
    func activeProjects() throws -> [Project] { projects.filter { $0.status == .active } }

    func items(in projectID: UUID) throws -> [KnowledgeItem] {
        itemsByProject[projectID] ?? []
    }

    func addItem(_ itemID: UUID, to projectID: UUID) throws {}
    func removeItem(_ itemID: UUID) throws {}
    func deleteProject(_ project: Project) throws {
        projects.removeAll { $0.id == project.id }
    }
    func setColor(_ projectID: UUID, hex: String) throws {}
    func derivedItems(in projectID: UUID) throws -> [ProjectDerivedItem] { [] }
    func totalContentCount(for projectID: UUID) throws -> Int { 0 }
}

// MARK: - MockKnowledgeItemService

@MainActor
final class MockKnowledgeItemService: KnowledgeItemServiceProtocol {
    var items: [KnowledgeItem] = []

    func createItem(
        type: KnowledgeItemType, title: String, bodyText: String?, folderID: UUID?, durationSeconds: Double?, languageCode: String?, tags: [String],
        inboxDate: Date?
    ) throws -> KnowledgeItem {
        let item = KnowledgeItem(
            type: type, title: title, bodyText: bodyText, folderID: folderID, durationSeconds: durationSeconds, languageCode: languageCode, inboxDate: inboxDate
        )
        items.append(item)
        return item
    }

    func fetchItem(id: UUID) throws -> KnowledgeItem? {
        items.first { $0.id == id }
    }

    func allItems() throws -> [KnowledgeItem] { items }
}

// MARK: - MockProjectDerivedItemService

@MainActor
final class MockProjectDerivedItemService: ProjectDerivedItemServiceProtocol {
    var items: [ProjectDerivedItem] = []

    func createTask(title: String, projectID: UUID, sourceItemID: UUID?, priority: TaskPriority, ownerName: String?, dueAt: Date?, bodyJSON: String?) throws
        -> ProjectDerivedItem
    {
        let item = ProjectDerivedItem(
            projectID: projectID, sourceItemID: sourceItemID, type: .task, title: title, bodyJSON: bodyJSON, status: .todo, priority: priority,
            ownerName: ownerName, dueAt: dueAt)
        items.append(item)
        return item
    }

    func createSignal(title: String, projectID: UUID, sourceItemID: UUID?, signalBody: SignalBody, confidence: Double?, isCritical: Bool) throws
        -> ProjectDerivedItem
    {
        let bodyData = try? JSONEncoder().encode(signalBody)
        let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }
        let item = ProjectDerivedItem(
            projectID: projectID, sourceItemID: sourceItemID, type: .signal, title: title, bodyJSON: bodyStr, status: .visible, confidence: confidence,
            isCritical: isCritical)
        items.append(item)
        return item
    }

    func createSynthesis(projectID: UUID, markdown: String, sections: [SynthesisSection], metrics: [SynthesisMetric], updatedFromItemIDs: [UUID]) throws
        -> ProjectDerivedItem
    {
        let item = ProjectDerivedItem(projectID: projectID, type: .synthesis, title: "Project Synthesis")
        items.append(item)
        return item
    }

    func fetch(id: UUID) throws -> ProjectDerivedItem? { items.first { $0.id == id } }
    func fetch(for projectID: UUID) throws -> [ProjectDerivedItem] { items.filter { $0.projectID == projectID } }
    func fetch(for projectID: UUID, type: ProjectDerivedType) throws -> [ProjectDerivedItem] {
        items.filter { $0.projectID == projectID && $0.type == type }
    }
    func fetchActiveTasks(for projectID: UUID) throws -> [ProjectDerivedItem] {
        items.filter { $0.projectID == projectID && $0.type == .task && $0.isActionable }
    }
    func fetchActiveSignals(for projectID: UUID) throws -> [ProjectDerivedItem] {
        items.filter { $0.projectID == projectID && $0.type == .signal && $0.isActionable }
    }
    func updateStatus(_ item: ProjectDerivedItem, to status: ProjectDerivedStatus) throws {
        item.statusRaw = status.rawValue
    }
    func updateTask(_ item: ProjectDerivedItem, title: String?, ownerName: String?, priority: TaskPriority?, dueAt: Date?) throws {
        if let t = title { item.title = t }
        if let o = ownerName { item.ownerName = o }
        if let p = priority { item.priorityRaw = p.rawValue }
        if let d = dueAt { item.dueAt = d }
    }
    func delete(_ item: ProjectDerivedItem) throws {
        items.removeAll { $0.id == item.id }
    }
}

// MARK: - MockGraphEdgeService

@MainActor
final class MockGraphEdgeService: GraphEdgeServiceProtocol {
    var edges: [GraphEdge] = []

    func create(fromID: UUID, toID: UUID, edgeType: EdgeType, weight: Double, provenanceItemID: UUID?, provenanceSegmentIDs: [String]) throws -> GraphEdge {
        let edge = GraphEdge(
            fromID: fromID, toID: toID, edgeType: edgeType, weight: weight, provenanceItemID: provenanceItemID, provenanceSegmentIDs: provenanceSegmentIDs)
        edges.append(edge)
        return edge
    }

    func find(fromID: UUID, toID: UUID, edgeType: EdgeType) throws -> GraphEdge? {
        edges.first { $0.fromID == fromID && $0.toID == toID && $0.edgeType == edgeType }
    }
    func edges(from nodeID: UUID) throws -> [GraphEdge] { edges.filter { $0.fromID == nodeID } }
    func edges(to nodeID: UUID) throws -> [GraphEdge] { edges.filter { $0.toID == nodeID } }
    func neighborhood(of nodeID: UUID, radius: Int) throws -> [GraphEdge] {
        edges.filter { $0.fromID == nodeID || $0.toID == nodeID }
    }
}

// MARK: - MockPersonService

@MainActor
final class MockPersonService: PersonServiceProtocol {
    var persons: [Person] = []

    func findOrCreate(displayName: String, email: String?, role: String?) throws -> Person {
        if let existing = persons.first(where: { $0.displayName.lowercased() == displayName.lowercased() }) {
            return existing
        }
        let p = Person(displayName: displayName, email: email, role: role)
        persons.append(p)
        return p
    }
    func fetch(id: UUID) throws -> Person? { persons.first { $0.id == id } }
    func all() throws -> [Person] { persons }
    func search(_ query: String) throws -> [Person] {
        persons.filter { $0.displayName.lowercased().contains(query.lowercased()) }
    }
}

// MARK: - MockEntityService

@MainActor
final class MockEntityService: EntityServiceProtocol {
    var entities: [Entity] = []

    func findOrCreate(kind: EntityKind, displayName: String) throws -> Entity {
        let key = "\(kind.rawValue):\(displayName.lowercased())"
        if let existing = entities.first(where: { $0.canonicalKey == key }) { return existing }
        let e = Entity(kind: kind, displayName: displayName)
        entities.append(e)
        return e
    }
    func fetch(id: UUID) throws -> Entity? { entities.first { $0.id == id } }
    func all(kind: EntityKind?) throws -> [Entity] {
        guard let kind else { return entities }
        return entities.filter { $0.kind == kind }
    }
    func search(_ query: String) throws -> [Entity] {
        entities.filter { $0.displayName.lowercased().contains(query.lowercased()) }
    }
}
