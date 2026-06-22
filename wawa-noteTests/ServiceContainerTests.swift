import XCTest
import SwiftData
@testable import Wawa_Note

@MainActor
final class ServiceContainerTests: XCTestCase {

    func testProductionContainerWiresAllServices() throws {
        let schema = Schema([
            KnowledgeItem.self, Project.self, Person.self,
            GraphEdge.self, Entity.self, QueueEntry.self,
            ProjectFrame.self, ChangeRecord.self, ProjectSnapshot.self,
            ProjectDerivedItem.self, AIProviderConfigModel.self, Folder.self, Annotation.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let svc = ServiceContainer(context: context)

        // Verify all properties are non-nil (existential types always are, but verify types)
        XCTAssertTrue(svc.projects is ProjectService)
        XCTAssertTrue(svc.items is KnowledgeItemService)
        XCTAssertTrue(svc.derived is ProjectDerivedItemService)
        XCTAssertTrue(svc.edges is GraphEdgeService)
        XCTAssertTrue(svc.persons is PersonService)
        XCTAssertTrue(svc.entities is EntityService)
    }

    func testTestContainerAcceptsMocks() throws {
        let mockProjects = MockProjectService()
        let mockItems = MockKnowledgeItemService()
        let mockDerived = MockProjectDerivedItemService()
        let mockEdges = MockGraphEdgeService()
        let mockPersons = MockPersonService()
        let mockEntities = MockEntityService()

        let svc = ServiceContainer(
            projects: mockProjects,
            items: mockItems,
            derived: mockDerived,
            edges: mockEdges,
            persons: mockPersons,
            entities: mockEntities
        )

        // Use through protocol — creates a project via mock
        let project = try svc.projects.create(name: "Test", summary: nil, iconName: nil)
        XCTAssertEqual(project.name, "Test")
        XCTAssertEqual(mockProjects.createCallCount, 1)
    }
}
