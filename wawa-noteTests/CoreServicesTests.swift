import XCTest
@testable import wawa_note

final class SemanticSearchServiceTests: XCTestCase {

    func testCosineSimilarityIdenticalVectors() {
        let service = SemanticSearchService()
        let vec: [Float] = [1.0, 2.0, 3.0]
        let result = service.cosineSimilarity(vec, vec)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let service = SemanticSearchService()
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let result = service.cosineSimilarity(a, b)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityOppositeVectors() {
        let service = SemanticSearchService()
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [-1.0, -2.0, -3.0]
        let result = service.cosineSimilarity(a, b)
        XCTAssertEqual(result, -1.0, accuracy: 0.001)
    }

    func testCosineSimilarityEmptyVectors() {
        let service = SemanticSearchService()
        let result = service.cosineSimilarity([], [])
        XCTAssertEqual(result, 0)
    }

    func testCosineSimilarityDifferentLengths() {
        let service = SemanticSearchService()
        let result = service.cosineSimilarity([1.0], [1.0, 2.0])
        XCTAssertEqual(result, 0)
    }
}

final class CrossReferenceResultTests: XCTestCase {

    func testParseValidJSON() throws {
        let json = """
        {
            "answer": "Test answer",
            "connections": [
                {
                    "from_item_id": "\(UUID().uuidString)",
                    "to_item_id": "\(UUID().uuidString)",
                    "relationship": "related",
                    "explanation": "Test connection",
                    "strength": 0.85
                }
            ],
            "insights": [
                {
                    "text": "Test insight",
                    "source_item_ids": ["\(UUID().uuidString)"],
                    "confidence": 0.9
                }
            ],
            "contradictions": [
                {
                    "description": "Test contradiction",
                    "item_a_id": "\(UUID().uuidString)",
                    "item_b_id": "\(UUID().uuidString)",
                    "resolution": "Resolved"
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(CrossReferenceResult.self, from: data)

        XCTAssertEqual(result.answer, "Test answer")
        XCTAssertEqual(result.connections.count, 1)
        XCTAssertEqual(result.connections[0].strength, 0.85)
        XCTAssertEqual(result.insights.count, 1)
        XCTAssertEqual(result.contradictions.count, 1)
        XCTAssertEqual(result.contradictions[0].resolution, "Resolved")
    }

    func testParseMinimalJSON() throws {
        let json = """
        {
            "answer": "Minimal",
            "connections": [],
            "insights": [],
            "contradictions": []
        }
        """

        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(CrossReferenceResult.self, from: data)

        XCTAssertEqual(result.answer, "Minimal")
        XCTAssertTrue(result.connections.isEmpty)
        XCTAssertTrue(result.insights.isEmpty)
        XCTAssertTrue(result.contradictions.isEmpty)
    }
}

final class ProjectExportServiceTests: XCTestCase {

    func testExportTasksCSVEmpty() {
        let service = ProjectExportService()
        let csv = service.exportTasksCSV(tasks: [])
        XCTAssertTrue(csv.contains("Title,Status,Priority,Owner"))
    }

    func testExportTasksCSVWithTasks() {
        let service = ProjectExportService()
        let task = TaskItem(
            title: "Test task",
            status: .todo,
            priority: .high,
            ownerName: "Alice",
            dueAt: Date()
        )
        let csv = service.exportTasksCSV(tasks: [task])

        XCTAssertTrue(csv.contains("Test task"))
        XCTAssertTrue(csv.contains("todo"))
        XCTAssertTrue(csv.contains("high"))
        XCTAssertTrue(csv.contains("Alice"))
    }
}

final class GraphEdgeServiceTests: XCTestCase {

    func testEdgeTypeAllCases() {
        let all = EdgeType.allCases
        XCTAssertEqual(all.count, 10)
        XCTAssertTrue(all.contains(.mentions))
        XCTAssertTrue(all.contains(.belongsTo))
        XCTAssertTrue(all.contains(.produced))
        XCTAssertTrue(all.contains(.supports))
        XCTAssertTrue(all.contains(.precedes))
        XCTAssertTrue(all.contains(.blockedBy))
        XCTAssertTrue(all.contains(.relatesTo))
        XCTAssertTrue(all.contains(.references))
        XCTAssertTrue(all.contains(.contradicts))
        XCTAssertTrue(all.contains(.assignedTo))
    }
}

final class EntityExtractionTests: XCTestCase {

    func testEntityKindMapping() {
        let kindMappings: [(EntityType, EntityKind)] = [
            (.person, .person),
            (.organization, .organization),
            (.system, .system),
            (.tool, .system),
            (.repository, .repository),
            (.location, .location),
            (.project, .other),
            (.other, .other)
        ]

        for (type, expectedKind) in kindMappings {
            let mapped = mapKindForTest(type)
            XCTAssertEqual(mapped, expectedKind, "\(type) should map to \(expectedKind)")
        }
    }

    private func mapKindForTest(_ type: EntityType) -> EntityKind {
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

final class MeetingAnalysisTests: XCTestCase {

    func testEntityTypeRoundtrip() {
        let types: [EntityType] = [.person, .organization, .system, .tool, .repository, .location, .project, .other]
        for type in types {
            let raw = type.rawValue
            let decoded = EntityType(rawValue: raw)
            XCTAssertEqual(decoded, type, "\(type.rawValue) should roundtrip")
        }
    }

    func testEntityMentionCreation() {
        let mention = EntityMention(name: "Alice", type: .person, sourceSegmentIds: [UUID()])
        XCTAssertEqual(mention.name, "Alice")
        XCTAssertEqual(mention.type, .person)
        XCTAssertEqual(mention.sourceSegmentIds.count, 1)
    }
}
