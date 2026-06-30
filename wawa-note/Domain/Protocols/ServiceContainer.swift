import Foundation
import SwiftData

// Related JIRA: KAN-11, KAN-56

/// Centralized dependency injection container for domain services.
/// Injected as @EnvironmentObject from WawaNoteApp. Consumers use protocol
/// types, enabling mock substitution in tests.
@MainActor
final class ServiceContainer: ObservableObject {
    let projects: any ProjectServiceProtocol
    let items: any KnowledgeItemServiceProtocol
    let derived: any ProjectDerivedItemServiceProtocol
    let edges: any GraphEdgeServiceProtocol
    let persons: any PersonServiceProtocol
    let entities: any EntityServiceProtocol

    /// Production initializer — wires all concrete service implementations.
    init(context: ModelContext) {
        let edgeSvc = GraphEdgeService(context: context)
        self.projects = ProjectService(context: context)
        self.items = KnowledgeItemService(context: context)
        self.derived = ProjectDerivedItemService(context: context, edgeService: edgeSvc)
        self.edges = edgeSvc
        self.persons = PersonService(context: context)
        self.entities = EntityService(context: context)
    }

    /// Test initializer — accepts any protocol-conforming implementations.
    init(
        projects: any ProjectServiceProtocol,
        items: any KnowledgeItemServiceProtocol,
        derived: any ProjectDerivedItemServiceProtocol,
        edges: any GraphEdgeServiceProtocol,
        persons: any PersonServiceProtocol,
        entities: any EntityServiceProtocol
    ) {
        self.projects = projects
        self.items = items
        self.derived = derived
        self.edges = edges
        self.persons = persons
        self.entities = entities
    }
}
