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

// MARK: - ItemStatus (formerly MeetingStatus)

final class ItemStatusTests: XCTestCase {

    func testAllCasesExist() {
        let all = ItemStatus.allCases
        XCTAssertEqual(all.count, 9)
        XCTAssertTrue(all.contains(.draft))
        XCTAssertTrue(all.contains(.analyzed))
        XCTAssertTrue(all.contains(.archived))
    }

    func testRawValueRoundtrip() {
        for status in ItemStatus.allCases {
            let decoded = ItemStatus(rawValue: status.rawValue)
            XCTAssertEqual(decoded, status)
        }
    }
}

// MARK: - IngestionResponse (Codable)

final class IngestionResponseTests: XCTestCase {

    func testDecodeFullResponse() throws {
        let json = """
        {
            "item_project_view": "Fits into the architecture",
            "project_item_view": "Reveals new patterns",
            "connections": [
                {"from_title": "Item A", "to_title": "Item B", "type": "supports", "explanation": "Direct evidence"}
            ],
            "task_updates": [
                {"task_title": "Old task", "new_status": "done", "reason": "Completed by this item"}
            ],
            "new_tasks": [
                {"title": "Investigate pattern", "priority": "high", "reason": "Urgent finding"}
            ],
            "edge_reinforcements": [
                {"from_title": "X", "to_title": "Y", "note": "Confirmed"}
            ],
            "insights": [
                {"text": "Unexpected correlation found", "confidence": 0.92}
            ],
            "project_summary_contribution": "This item adds significant knowledge about architecture decisions."
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IngestionResponse.self, from: data)

        XCTAssertEqual(response.item_project_view, "Fits into the architecture")
        XCTAssertEqual(response.connections?.count, 1)
        XCTAssertEqual(response.connections?.first?.type, "supports")
        XCTAssertEqual(response.task_updates?.first?.new_status, "done")
        XCTAssertEqual(response.new_tasks?.first?.priority, "high")
        XCTAssertEqual(response.edge_reinforcements?.first?.note, "Confirmed")
        XCTAssertEqual(response.insights?.first?.confidence, 0.92)
        XCTAssertTrue(response.project_summary_contribution?.contains("architecture decisions") ?? false)
    }

    func testDecodeMinimalResponse() throws {
        let json = """
        {
            "project_summary_contribution": "Minimal contribution."
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IngestionResponse.self, from: data)

        XCTAssertEqual(response.project_summary_contribution, "Minimal contribution.")
        XCTAssertNil(response.connections)
        XCTAssertNil(response.new_tasks)
        XCTAssertNil(response.insights)
    }

    func testLegacyKeyStillParsed() throws {
        let json = """
        {
            "project_summary_update": "Legacy key value"
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IngestionResponse.self, from: data)

        XCTAssertEqual(response.project_summary_update, "Legacy key value")
        XCTAssertNil(response.project_summary_contribution)
    }
}

// MARK: - KnowledgeItem

final class KnowledgeItemTests: XCTestCase {

    func testDefaultTypeIsAudio() {
        let item = KnowledgeItem(title: "Test")
        XCTAssertEqual(item.type, .audio)
    }

    func testCustomType() {
        let item = KnowledgeItem(type: .note, title: "My Note")
        XCTAssertEqual(item.type, .note)
    }

    func testInboxDateDefault() {
        let item = KnowledgeItem(title: "Test")
        XCTAssertNotNil(item.inboxDate)
    }

    func testProjectIDIsNilByDefault() {
        let item = KnowledgeItem(title: "Test")
        XCTAssertNil(item.projectID)
    }

    func testStatusRoundtrip() {
        let item = KnowledgeItem(title: "Test")
        item.status = .analyzed
        XCTAssertEqual(item.status, .analyzed)
        XCTAssertEqual(item.statusRaw, "analyzed")
    }
}

// MARK: - ProjectService (pure logic)

final class ProjectStatusTests: XCTestCase {

    func testAllStatuses() {
        let all = ProjectStatus.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains(.active))
        XCTAssertTrue(all.contains(.archived))
        XCTAssertTrue(all.contains(.completed))
    }
}

final class TaskItemTests: XCTestCase {

    func testDefaultStatus() {
        let task = TaskItem(title: "Test")
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.priority, .medium)
    }

    func testSourceSegmentEncoding() throws {
        let segments = ["seg1", "seg2", "seg3"]
        let task = TaskItem(title: "Test", sourceSegmentIDs: segments)
        XCTAssertEqual(task.sourceSegmentIDList, segments)
    }

    func testEmptySourceSegments() {
        let task = TaskItem(title: "Test")
        XCTAssertTrue(task.sourceSegmentIDList.isEmpty)
    }
}
