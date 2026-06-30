import SwiftData
import WawaNoteCore
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

// MARK: - ProjectDerivedItemService Tests

@MainActor
final class ProjectDerivedItemServiceTests: XCTestCase {
  var container: ModelContainer!
  var context: ModelContext!
  var service: ProjectDerivedItemService!

  override func setUp() async throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    container = try ModelContainer(
      for: ProjectDerivedItem.self, GraphEdge.self, configurations: config)
    context = container.mainContext
    service = ProjectDerivedItemService(context: context)
  }

  override func tearDown() async throws {
    service = nil
    context = nil
    container = nil
  }

  func testCreateTask() throws {
    let projectID = UUID()
    let item = try service.createTask(
      title: "Review contract",
      projectID: projectID,
      priority: .high,
      ownerName: "Alice"
    )
    XCTAssertEqual(item.type, .task)
    XCTAssertEqual(item.title, "Review contract")
    XCTAssertEqual(item.status, .todo)
    XCTAssertEqual(item.priorityRaw, "high")
  }

  func testCreateSignal() throws {
    let projectID = UUID()
    let body = SignalBody(signalType: "risk", description: "Deadline at risk")
    let item = try service.createSignal(
      title: "Deadline risk",
      projectID: projectID,
      signalBody: body,
      confidence: 0.9,
      isCritical: true
    )
    XCTAssertEqual(item.type, .signal)
    XCTAssertTrue(item.isCritical)
    XCTAssertEqual(item.confidence, 0.9)
  }

  func testFetchForProject() throws {
    let pid = UUID()
    try service.createTask(title: "Task A", projectID: pid)
    try service.createTask(title: "Task B", projectID: pid)
    try service.createSignal(
      title: "Signal X", projectID: pid,
      signalBody: SignalBody(signalType: "alert", description: "test"))

    let all = try service.fetch(for: pid)
    XCTAssertEqual(all.count, 3)
  }

  func testFetchByType() throws {
    let pid = UUID()
    try service.createTask(title: "T1", projectID: pid)
    try service.createTask(title: "T2", projectID: pid)
    try service.createSignal(
      title: "S1", projectID: pid, signalBody: SignalBody(signalType: "alert", description: "test"))

    let tasks = try service.fetch(for: pid, type: .task)
    XCTAssertEqual(tasks.count, 2)

    let signals = try service.fetch(for: pid, type: .signal)
    XCTAssertEqual(signals.count, 1)
  }

  func testUpdateStatus() throws {
    let pid = UUID()
    let task = try service.createTask(title: "Test", projectID: pid)
    try service.updateStatus(task, to: .done)
    XCTAssertEqual(task.status, .done)
    XCTAssertFalse(task.isActionable)
    XCTAssertTrue(task.isResolved)
  }

  func testDeleteDerivedItem() throws {
    let pid = UUID()
    let task = try service.createTask(title: "Delete me", projectID: pid)
    let tid = task.id
    try service.delete(task)
    let fetched = try service.fetch(id: tid)
    XCTAssertNil(fetched)
  }
}

// MARK: - Migration Tests

@MainActor
final class ProjectDerivedItemMigrationTests: XCTestCase {

  func testMigrationFromTaskItemAndAgentSuggestion() throws {
    let schema = Schema([
      TaskItem.self,
      AgentSuggestion.self,
      ProjectDerivedItem.self,
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: config)
    let context = container.mainContext

    let projectID = UUID()

    // Create source items
    let task = TaskItem(
      projectID: projectID, title: "Review contract", status: .inProgress, priority: .high)
    context.insert(task)
    let signal = AgentSuggestion(projectID: projectID, type: "risk", title: "Deadline risk")
    context.insert(signal)
    try context.save()

    // Reset UserDefaults flag that may have been set by previous test runs
    UserDefaults.standard.removeObject(forKey: "migration_to_project_derived_v1")

    // Call the actual migration method
    ProjectService.migrateToProjectDerivedItems(context: context)

    // Verify items were created
    let allDerived = try context.fetch(FetchDescriptor<ProjectDerivedItem>())
    XCTAssertEqual(allDerived.count, 2, "Migration should create 2 items")

    // Verify field mapping
    let tasks = try context.fetch(
      FetchDescriptor<ProjectDerivedItem>(
        predicate: #Predicate { $0.projectID == projectID && $0.typeRaw == "task" }
      )
    )
    let signals = try context.fetch(
      FetchDescriptor<ProjectDerivedItem>(
        predicate: #Predicate { $0.projectID == projectID && $0.typeRaw == "signal" }
      )
    )
    XCTAssertEqual(tasks[0].title, "Review contract")
    XCTAssertEqual(tasks[0].status, .inProgress)
    XCTAssertEqual(signals[0].title, "Deadline risk")
    XCTAssertEqual(signals[0].status, .visible)

    // Run migration again — UserDefaults flag should prevent duplicate creation
    ProjectService.migrateToProjectDerivedItems(context: context)
    let after = try context.fetch(FetchDescriptor<ProjectDerivedItem>())
    XCTAssertEqual(after.count, 2, "Migration should be idempotent — no duplicates")
  }

  func testMigrationSkipsItemsWithoutProjectID() throws {
    let schema = Schema([
      TaskItem.self,
      AgentSuggestion.self,
      ProjectDerivedItem.self,
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: config)
    let context = container.mainContext

    // TaskItem without projectID
    let orphanTask = TaskItem(projectID: nil, title: "Orphan task")
    context.insert(orphanTask)
    // AgentSuggestion without projectID
    let orphanSignal = AgentSuggestion(projectID: nil, type: "alert", title: "Orphan signal")
    context.insert(orphanSignal)
    try context.save()

    ProjectService.migrateToProjectDerivedItems(context: context)

    let allDerived = try context.fetch(FetchDescriptor<ProjectDerivedItem>())
    XCTAssertTrue(allDerived.isEmpty, "Orphan items without projectID should not be migrated")
  }
}
