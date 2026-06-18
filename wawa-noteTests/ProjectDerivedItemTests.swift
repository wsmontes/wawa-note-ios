import XCTest
@testable import Wawa_Note

@MainActor
final class ProjectDerivedItemTests: XCTestCase {

    func testTaskCreation() {
        let item = ProjectDerivedItem(
            projectID: UUID(),
            type: .task,
            title: "Test task",
            status: .todo,
            priority: .high,
            ownerName: "Alice",
            dueAt: Date().addingTimeInterval(86400)
        )
        XCTAssertEqual(item.type, .task)
        XCTAssertEqual(item.status, .todo)
        XCTAssertEqual(item.priorityRaw, "high")
        XCTAssertTrue(item.isActionable)
        XCTAssertFalse(item.isResolved)
    }

    func testSignalCreation() {
        let body = SignalBody(
            signalType: "risk",
            description: "Budget overrun risk",
            suggestedAction: "Review budget allocation",
            impactScore: 0.8,
            urgencyScore: 0.6
        )
        let bodyJSON = try! JSONEncoder().encode(body)
        let bodyStr = String(data: bodyJSON, encoding: .utf8)

        let item = ProjectDerivedItem(
            projectID: UUID(),
            type: .signal,
            title: "Budget risk detected",
            bodyJSON: bodyStr,
            status: .visible,
            confidence: 0.85,
            isCritical: true
        )
        XCTAssertEqual(item.type, .signal)
        XCTAssertTrue(item.isActionable)
        XCTAssertTrue(item.isCritical)
        XCTAssertEqual(item.displayIcon, "exclamationmark.triangle.fill")
    }

    func testSynthesisCreation() {
        let item = ProjectDerivedItem(
            projectID: UUID(),
            type: .synthesis,
            title: "Project Synthesis"
        )
        XCTAssertEqual(item.type, .synthesis)
        XCTAssertFalse(item.isActionable)
        XCTAssertFalse(item.isResolved)
    }

    func testStatusTransitions() {
        let item = ProjectDerivedItem(
            projectID: UUID(),
            type: .task,
            title: "Test",
            status: .todo
        )
        XCTAssertTrue(item.isActionable)

        // Simulate status update via service
        // (Direct mutation not allowed on @Model without context, test via service in next task)
    }

    func testSignalBodyRoundtrip() {
        let original = SignalBody(
            signalType: "opportunity",
            description: "New market segment identified",
            suggestedAction: "Research segment size",
            relatedItemIDs: [UUID(), UUID()],
            impactScore: 0.7,
            urgencyScore: 0.3
        )
        let encoded = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(SignalBody.self, from: encoded)
        XCTAssertEqual(decoded.signalType, "opportunity")
        XCTAssertEqual(decoded.impactScore, 0.7)
    }
}
