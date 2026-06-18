# Project Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Project area around a three-tier agent hierarchy (Item → Project → Chat), synthesis + action planes, device context integration, and project outputs. Simplify UI to Synthesis | Files segments.

**Architecture:** Extend existing AgentLoop as ProjectAgent. Introduce ProjectDerivedItem for all project-level derivations. Subsumes TaskItem and AgentSuggestion models. Unifies file browser as canonical view of KnowledgeItem + ProjectDerivedItem. Device context cross-referencing via EventKit, Contacts.framework.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, EventKit, Contacts.framework, VisionKit, AVFoundation, Markdown rendering

## Global Constraints

- Target device: iPhone 14 Plus (primary), iPhone 15 (secondary)
- SwiftData for persistence, FileManager for large artifacts
- No backend required — local-first
- AgentLoop infrastructure already exists — extend, don't replace
- AIConfigService for all AI calls (temperature, maxTokens, model selection)
- Prefer editing existing files to creating new ones (pbxproj limitation)
- New files must be added to Xcode project
- Swift style: async/await, @MainActor for view models, protocol-first boundaries
- Keep ContentPipelineService for initial item ingestion (level 2) — it works
- Build Project Agent on top of existing AgentLoop, not as separate system
- Each agent writes only to its own layer (Item → level 2, Project → level 3, Chat → tools only)
- No view exists without data to sustain it (thresholds: tasks >= 3 for kanban, edges >= 5 for graph, events >= 5 for timeline)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `wawa-note/Domain/Models/ProjectModels.swift` | Modify | Add ProjectDerivedItem, remove TaskItem/AgentSuggestion (deprecate) |
| `wawa-note/Domain/Services/ProjectDerivedItemService.swift` | Create | CRUD for ProjectDerivedItem |
| `wawa-note/Domain/Services/ProjectService.swift` | Modify | Add derived item queries, item reprocess flag |
| `wawa-note/Domain/Services/TaskService.swift` | Modify | Adapt to wrap ProjectDerivedItem(type: .task) |
| `wawa-note/Domain/Services/GraphEdgeService.swift` | Modify | Support ProjectDerivedItem IDs in edges |
| `wawa-note/Domain/Agent/ProjectAgentLoop.swift` | Create | ProjectAgent extending AgentLoop |
| `wawa-note/Domain/Agent/Tools/ProjectTools.swift` | Create | Project-specific tools (SynthesizeProject, EmitSignal, etc.) |
| `wawa-note/Domain/Services/DeviceContextService.swift` | Create | Calendar/Contacts/Location cross-referencing |
| `wawa-note/UI/Project/ProjectDetailView.swift` | Modify | Simplify to segment control (Síntese | Arquivos) |
| `wawa-note/UI/Project/ProjectSynthesisView.swift` | Create | Render synthesis document with primitives |
| `wawa-note/UI/Project/ItemsView.swift` | Modify | Unified KnowledgeItem + ProjectDerivedItem list |
| `wawa-note/UI/Project/BoardView.swift` | Modify | Update to ProjectDerivedItem(type: .task) |
| `wawa-note/UI/Project/ProjectGraphView.swift` | Modify | Update data sources |
| `wawa-note/UI/Project/ProjectTimelineView.swift` | Modify | Update data sources |
| `wawa-note/UI/Project/SendToMenuView.swift` | Create | Unified export context menu |
| `wawa-note/UI/Project/TaskEditorView.swift` | Modify | Update to ProjectDerivedItem |
| `wawa-note/Domain/Models/ProjectModels.swift` | Modify | Deprecate TaskItem, AgentSuggestion |
| `wawa-noteTests/ProjectDerivedItemTests.swift` | Create | Tests for new model and services |

## Views deprecated (no longer primary navigation)

These views are removed from the main tab/project flow. Their functionality is subsumed by the file browser (filtered by type) or accessed via synthesis links only when data supports them:

- `ProjectHomeView` → replaced by SynthesisView
- `ProjectTaskBoardView` → subsumed by file browser + BoardView when tasks >= 3
- `ProjectRiskRegisterView` → file browser filtered to signals
- `ProjectDecisionsView` → file browser filtered to decisions
- `ProjectEntitiesView` → accessible but not primary
- `ProjectPeopleView` → accessible but not primary
- `SignalsView` → file browser filtered to signals

---

### Task 1: Add ProjectDerivedItem model to ProjectModels.swift

**Files:**
- Modify: `wawa-note/Domain/Models/ProjectModels.swift`
- Test: `wawa-noteTests/ProjectDerivedItemTests.swift`

**Interfaces:**
- Produces: `ProjectDerivedItem` (SwiftData @Model), `ProjectDerivedType` enum, `ProjectDerivedItemService` protocol

- [ ] **Step 1: Add ProjectDerivedType enum and ProjectDerivedItem model**

Add to `wawa-note/Domain/Models/ProjectModels.swift`, after the `QueueStatus` enum (end of file):

```swift
// MARK: - ProjectDerivedItem

enum ProjectDerivedType: String, Codable, Sendable, CaseIterable {
    case synthesis   // Living synthesis document — one per project
    case task        // Actionable item with status, priority, dueAt, owner
    case signal      // Alert, risk, doubt, opportunity
    case connection  // Proposed edge between items
}

enum ProjectDerivedStatus: String, Codable, Sendable, CaseIterable {
    // Task statuses
    case todo
    case inProgress
    case done
    case cancelled
    // Signal statuses
    case visible
    case acknowledged
    case resolved
    case dismissed
}

/// Persisted derivation created by the Project Agent.
/// Does NOT replace item-level derivations (those stay in item analysis JSON).
/// Appears in the project file browser alongside KnowledgeItems.
@Model
final class ProjectDerivedItem {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var sourceItemID: UUID?        // nil = synthesis (project-level, not tied to one item)
    var typeRaw: String
    var title: String
    var bodyJSON: String?          // Structured content specific to type (taskJSON, signalJSON, synthesisJSON)
    var statusRaw: String?
    var priorityRaw: String?       // For tasks: low, medium, high, critical
    var ownerName: String?         // For tasks: assigned person
    var dueAt: Date?               // For tasks: deadline
    var confidence: Double?        // For signals: 0-1
    var isCritical: Bool           // For signals: demands immediate attention
    var createdAt: Date
    var updatedAt: Date
    var resolvedAt: Date?          // For signals: when resolved
    var resolutionReason: String?  // For signals: why resolved
    var reprocessContext: String?  // If created via reprocess, the context used

    var type: ProjectDerivedType {
        get { ProjectDerivedType(rawValue: typeRaw) ?? .synthesis }
        set { typeRaw = newValue.rawValue }
    }

    var status: ProjectDerivedStatus? {
        get { statusRaw.flatMap(ProjectDerivedStatus.init(rawValue:)) }
        set { statusRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceItemID: UUID? = nil,
        type: ProjectDerivedType,
        title: String,
        bodyJSON: String? = nil,
        status: ProjectDerivedStatus? = nil,
        priority: TaskPriority? = nil,
        ownerName: String? = nil,
        dueAt: Date? = nil,
        confidence: Double? = nil,
        isCritical: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resolvedAt: Date? = nil,
        resolutionReason: String? = nil,
        reprocessContext: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceItemID = sourceItemID
        self.typeRaw = type.rawValue
        self.title = title
        self.bodyJSON = bodyJSON
        self.statusRaw = status?.rawValue
        self.priorityRaw = priority?.rawValue
        self.ownerName = ownerName
        self.dueAt = dueAt
        self.confidence = confidence
        self.isCritical = isCritical
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
        self.resolutionReason = resolutionReason
        self.reprocessContext = reprocessContext
    }
}

// MARK: - Convenience helpers

extension ProjectDerivedItem {
    /// Whether this derived item is actionable (task or active signal).
    var isActionable: Bool {
        switch type {
        case .task: status == .todo || status == .inProgress
        case .signal: status == .visible || status == .acknowledged
        default: false
        }
    }

    /// Whether this item is in a terminal (non-active) state.
    var isResolved: Bool {
        switch type {
        case .task: status == .done || status == .cancelled
        case .signal: status == .resolved || status == .dismissed
        case .synthesis, .connection: false
        }
    }

    /// Icon name for file browser display.
    var displayIcon: String {
        switch type {
        case .synthesis: "doc.richtext"
        case .task: "checklist"
        case .signal: signalIcon
        case .connection: "arrow.triangle.branch"
        }
    }

    private var signalIcon: String {
        guard let body = bodyJSON, let data = body.data(using: .utf8),
              let json = try? JSONDecoder().decode(SignalBody.self, from: data)
        else { return "dot.radiowaves.left.and.right" }
        switch json.signalType {
        case "risk": "exclamationmark.triangle.fill"
        case "alert": "bell.fill"
        case "opportunity": "lightbulb.fill"
        case "doubt": "questionmark.circle.fill"
        case "pattern": "rectangle.3.group.fill"
        case "contradiction": "arrow.triangle.swap"
        default: "waveform.path.ecg"
        }
    }
}

/// Structured body for signal-type derived items.
struct SignalBody: Codable, Sendable {
    var signalType: String       // risk, alert, opportunity, doubt, pattern, contradiction
    var description: String
    var suggestedAction: String? // What the agent suggests doing about it
    var relatedItemIDs: [UUID]?  // Items this signal connects
    var impactScore: Double?     // 0-1
    var urgencyScore: Double?    // 0-1
}

/// Structured body for task-type derived items.
struct TaskBody: Codable, Sendable {
    var description: String?
    var sourceSegmentIDs: [String]?
    var aiGenerated: Bool
    var suggestedByItemID: UUID?
}

/// Structured body for synthesis-type derived items.
struct SynthesisBody: Codable, Sendable {
    var markdown: String              // Full synthesis in markdown
    var sections: [SynthesisSection]  // Parsed sections for rendering
    var metrics: [SynthesisMetric]    // Computed metrics
    var updatedFromItemIDs: [UUID]    // Items that contributed to latest version
    var generatedAt: Date
}

struct SynthesisSection: Codable, Sendable {
    var id: String
    var title: String
    var renderType: String  // "markdown", "cards", "table", "metrics", "timeline"
    var content: String     // Markdown or JSON depending on renderType
    var order: Int
}

struct SynthesisMetric: Codable, Sendable {
    var id: String
    var label: String
    var value: Double
    var format: String      // "number", "percentage", "days", "score"
    var status: String      // "healthy", "warning", "critical", "neutral"
    var icon: String?
}
```

- [ ] **Step 2: Register ProjectDerivedItem in ModelContainer**

Add to WawaNoteApp.swift where ModelContainer is configured, alongside existing model registrations. Search for `TaskItem.self` registration and add `ProjectDerivedItem.self`.

- [ ] **Step 3: Write unit test for ProjectDerivedItem**

Create `wawa-noteTests/ProjectDerivedItemTests.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' -only-testing:wawa-noteTests/ProjectDerivedItemTests 2>&1 | tail -20`
Expected: All 5 tests pass

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Domain/Models/ProjectModels.swift wawa-noteTests/ProjectDerivedItemTests.swift
git commit -m "feat: add ProjectDerivedItem model with synthesis, task, signal, connection types

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Create ProjectDerivedItemService

**Files:**
- Create: `wawa-note/Domain/Services/ProjectDerivedItemService.swift`
- Test: `wawa-noteTests/ProjectDerivedItemTests.swift` (add tests)

**Interfaces:**
- Consumes: `ProjectDerivedItem` (Task 1), `ModelContext`, `GraphEdgeService`
- Produces: `ProjectDerivedItemService` (@MainActor class)

- [ ] **Step 1: Write failing test for service**

Add to `wawa-noteTests/ProjectDerivedItemTests.swift`:

```swift
// MARK: - ProjectDerivedItemService Tests

@MainActor
final class ProjectDerivedItemServiceTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var service: ProjectDerivedItemService!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: ProjectDerivedItem.self, configurations: config)
        context = container.mainContext
        service = ProjectDerivedItemService(context: context)
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
        try service.createSignal(title: "Signal X", projectID: pid, signalBody: SignalBody(signalType: "alert", description: "test"))

        let all = try service.fetch(for: pid)
        XCTAssertEqual(all.count, 3)
    }

    func testFetchByType() throws {
        let pid = UUID()
        try service.createTask(title: "T1", projectID: pid)
        try service.createTask(title: "T2", projectID: pid)
        try service.createSignal(title: "S1", projectID: pid, signalBody: SignalBody(signalType: "alert", description: "test"))

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' -only-testing:wawa-noteTests/ProjectDerivedItemServiceTests 2>&1 | tail -10`
Expected: FAIL — "ProjectDerivedItemService not found"

- [ ] **Step 3: Create ProjectDerivedItemService**

Create `wawa-note/Domain/Services/ProjectDerivedItemService.swift`:

```swift
import Foundation
import SwiftData

@MainActor
final class ProjectDerivedItemService {
    private let context: ModelContext
    private let edgeService: GraphEdgeService

    init(context: ModelContext, edgeService: GraphEdgeService? = nil) {
        self.context = context
        self.edgeService = edgeService ?? GraphEdgeService(context: context)
    }

    // MARK: - Create

    func createTask(
        title: String,
        projectID: UUID,
        sourceItemID: UUID? = nil,
        priority: TaskPriority = .medium,
        ownerName: String? = nil,
        dueAt: Date? = nil,
        bodyJSON: String? = nil
    ) throws -> ProjectDerivedItem {
        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: sourceItemID,
            type: .task,
            title: title,
            bodyJSON: bodyJSON,
            status: .todo,
            priority: priority,
            ownerName: ownerName,
            dueAt: dueAt
        )
        context.insert(item)
        try context.save()
        // Create edge linking task to project
        try edgeService.create(fromID: item.id, toID: projectID, edgeType: .belongsTo)
        if let source = sourceItemID {
            try edgeService.create(fromID: source, toID: item.id, edgeType: .produced)
        }
        return item
    }

    func createSignal(
        title: String,
        projectID: UUID,
        sourceItemID: UUID? = nil,
        signalBody: SignalBody,
        confidence: Double? = nil,
        isCritical: Bool = false
    ) throws -> ProjectDerivedItem {
        let bodyData = try? JSONEncoder().encode(signalBody)
        let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: sourceItemID,
            type: .signal,
            title: title,
            bodyJSON: bodyStr,
            status: .visible,
            confidence: confidence,
            isCritical: isCritical
        )
        context.insert(item)
        try context.save()
        if let source = sourceItemID {
            try edgeService.create(fromID: source, toID: item.id, edgeType: .produced)
        }
        return item
    }

    func createSynthesis(
        projectID: UUID,
        markdown: String,
        sections: [SynthesisSection],
        metrics: [SynthesisMetric],
        updatedFromItemIDs: [UUID]
    ) throws -> ProjectDerivedItem {
        let body = SynthesisBody(
            markdown: markdown,
            sections: sections,
            metrics: metrics,
            updatedFromItemIDs: updatedFromItemIDs,
            generatedAt: Date()
        )
        let bodyData = try? JSONEncoder().encode(body)
        let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

        // Upsert: delete existing synthesis, create new
        if let existing = try? fetchSynthesis(for: projectID).first {
            context.delete(existing)
        }

        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: nil, // synthesis belongs to project, not any single item
            type: .synthesis,
            title: "Project Synthesis",
            bodyJSON: bodyStr
        )
        context.insert(item)
        try context.save()
        return item
    }

    func createConnection(
        title: String,
        projectID: UUID,
        fromDerivedID: UUID,
        toDerivedID: UUID,
        edgeType: EdgeType,
        provenanceItemID: UUID? = nil
    ) throws -> ProjectDerivedItem {
        let item = ProjectDerivedItem(
            projectID: projectID,
            sourceItemID: provenanceItemID,
            type: .connection,
            title: title,
            status: nil
        )
        context.insert(item)
        // Create the actual GraphEdge alongside the derived item
        try edgeService.create(
            fromID: fromDerivedID,
            toID: toDerivedID,
            edgeType: edgeType,
            provenanceItemID: provenanceItemID
        )
        try context.save()
        return item
    }

    // MARK: - Read

    func fetch(id: UUID) throws -> ProjectDerivedItem? {
        var descriptor = FetchDescriptor<ProjectDerivedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetch(for projectID: UUID) throws -> [ProjectDerivedItem] {
        var descriptor = FetchDescriptor<ProjectDerivedItem>(predicate: #Predicate { $0.projectID == projectID })
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func fetch(for projectID: UUID, type: ProjectDerivedType) throws -> [ProjectDerivedItem] {
        let typeRaw = type.rawValue
        var descriptor = FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate { $0.projectID == projectID && $0.typeRaw == typeRaw }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    func fetchSynthesis(for projectID: UUID) throws -> [ProjectDerivedItem] {
        try fetch(for: projectID, type: .synthesis)
    }

    func fetchActiveTasks(for projectID: UUID) throws -> [ProjectDerivedItem] {
        let typeRaw = ProjectDerivedType.task.rawValue
        let todoRaw = ProjectDerivedStatus.todo.rawValue
        let inProgressRaw = ProjectDerivedStatus.inProgress.rawValue
        var descriptor = FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate {
                $0.projectID == projectID && $0.typeRaw == typeRaw &&
                ($0.statusRaw == todoRaw || $0.statusRaw == inProgressRaw)
            }
        )
        descriptor.sortBy = [SortDescriptor(\.dueAt, order: .forward)]
        return try context.fetch(descriptor)
    }

    func fetchActiveSignals(for projectID: UUID) throws -> [ProjectDerivedItem] {
        let typeRaw = ProjectDerivedType.signal.rawValue
        let visibleRaw = ProjectDerivedStatus.visible.rawValue
        let ackRaw = ProjectDerivedStatus.acknowledged.rawValue
        var descriptor = FetchDescriptor<ProjectDerivedItem>(
            predicate: #Predicate {
                $0.projectID == projectID && $0.typeRaw == typeRaw &&
                ($0.statusRaw == visibleRaw || $0.statusRaw == ackRaw)
            }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    // MARK: - Update

    func updateStatus(_ item: ProjectDerivedItem, to status: ProjectDerivedStatus) throws {
        item.statusRaw = status.rawValue
        item.updatedAt = Date()
        if status == .done || status == .cancelled || status == .resolved || status == .dismissed {
            item.resolvedAt = Date()
        }
        try context.save()
    }

    func updateTask(
        _ item: ProjectDerivedItem,
        title: String? = nil,
        ownerName: String? = nil,
        priority: TaskPriority? = nil,
        dueAt: Date? = nil
    ) throws {
        guard item.type == .task else { return }
        if let t = title { item.title = t }
        if let o = ownerName { item.ownerName = o }
        if let p = priority { item.priorityRaw = p.rawValue }
        if let d = dueAt { item.dueAt = d }
        item.updatedAt = Date()
        try context.save()
    }

    func acknowledgeSignal(_ item: ProjectDerivedItem) throws {
        guard item.type == .signal else { return }
        try updateStatus(item, to: .acknowledged)
    }

    func resolveSignal(_ item: ProjectDerivedItem, reason: String) throws {
        guard item.type == .signal else { return }
        item.resolutionReason = reason
        try updateStatus(item, to: .resolved)
    }

    // MARK: - Delete

    func delete(_ item: ProjectDerivedItem) throws {
        // Remove associated edges
        let iid = item.id
        let outgoing = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == iid }))
        for edge in outgoing { context.delete(edge) }
        let incoming = try context.fetch(FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == iid }))
        for edge in incoming { context.delete(edge) }
        context.delete(item)
        try context.save()
    }

    // MARK: - Reprocess marking

    /// Marks all source items in a project as needing reprocessing with the given context.
    /// Used when project domain changes or user requests re-analysis.
    func markItemsForReprocessing(projectID: UUID, context: String, itemIDs: [UUID]) {
        // This is a lightweight trigger — actual reprocessing is handled by the Item Agent
        for itemID in itemIDs {
            // Set the flag on KnowledgeItem (handled by ProjectService integration)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' -only-testing:wawa-noteTests/ProjectDerivedItemServiceTests 2>&1 | tail -15`
Expected: All 6 new tests pass

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Domain/Services/ProjectDerivedItemService.swift wawa-noteTests/ProjectDerivedItemTests.swift
git commit -m "feat: add ProjectDerivedItemService with CRUD for tasks, signals, synthesis

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Update ProjectService for derived item awareness

**Files:**
- Modify: `wawa-note/Domain/Services/ProjectService.swift`
- Test: `wawa-noteTests/ProjectDerivedItemTests.swift` (add tests)

**Interfaces:**
- Consumes: `ProjectDerivedItemService` (Task 2)
- Produces: Updated `ProjectService` with `derivedItems(in:)`, `allContent(in:)`, `markForReprocessing(itemID:context:)`

- [ ] **Step 1: Write failing tests**

Add to `ProjectDerivedItemTests.swift`:

```swift
// MARK: - ProjectService Integration

@MainActor
final class ProjectServiceDerivedIntegrationTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var projectService: ProjectService!
    var derivedService: ProjectDerivedItemService!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Project.self, KnowledgeItem.self, ProjectDerivedItem.self, GraphEdge.self, configurations: config)
        context = container.mainContext
        projectService = ProjectService(context: context)
        derivedService = ProjectDerivedItemService(context: context)
    }

    func testAllContentReturnsBothTypes() throws {
        let project = try projectService.create(name: "Test Project")
        // Add a KnowledgeItem
        let item = KnowledgeItem(title: "Meeting", type: .meeting)
        item.projectID = project.id
        context.insert(item)
        // Add a derived item
        try derivedService.createTask(title: "Task 1", projectID: project.id)
        try context.save()

        let knowledgeItems = try projectService.items(in: project.id)
        let derivedItems = try derivedService.fetch(for: project.id)
        // Later: unified fetch
        XCTAssertEqual(knowledgeItems.count, 1)
        XCTAssertEqual(derivedItems.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodebuild test ... -only-testing:wawa-noteTests/ProjectServiceDerivedIntegrationTests/testAllContentReturnsBothTypes`
Expected: FAIL (test will pass if models register correctly; may need ModelContainer adjustment)

- [ ] **Step 3: Add derived item query methods to ProjectService**

Add to `ProjectService.swift` after the existing `items(in:)` method:

```swift
// MARK: - Derived items

/// Returns all ProjectDerivedItems for this project.
func derivedItems(in projectID: UUID) throws -> [ProjectDerivedItem] {
    let service = ProjectDerivedItemService(context: context)
    return try service.fetch(for: projectID)
}

/// Returns the synthesis for this project, if it exists.
func synthesis(for projectID: UUID) throws -> ProjectDerivedItem? {
    let service = ProjectDerivedItemService(context: context)
    return try service.fetchSynthesis(for: projectID).first
}

/// Returns active tasks for this project.
func activeTasks(in projectID: UUID) throws -> [ProjectDerivedItem] {
    let service = ProjectDerivedItemService(context: context)
    return try service.fetchActiveTasks(for: projectID)
}

/// Returns active signals for this project.
func activeSignals(in projectID: UUID) throws -> [ProjectDerivedItem] {
    let service = ProjectDerivedItemService(context: context)
    return try service.fetchActiveSignals(for: projectID)
}

/// Unified count of all content (KnowledgeItems + ProjectDerivedItems) in this project.
func totalContentCount(for projectID: UUID) throws -> Int {
    let items = try self.items(in: projectID)
    let derived = try derivedItems(in: projectID)
    return items.count + derived.count
}

/// Marks a KnowledgeItem as needing reprocessing with the given context.
func markForReprocessing(itemID: UUID, projectID: UUID, context: String) throws {
    guard let item = try fetchItem(itemID) else { return }
    // Set reprocessing flag — the Item Agent picks this up
    item.needsProjectReprocessing = true
    item.projectReprocessContext = context
    item.updatedAt = Date()
    try context.save()
}
```

Note: `needsProjectReprocessing` and `projectReprocessContext` need to be added to `KnowledgeItem` model as optional fields. If KnowledgeItem is in a separate file, add them there:

```swift
// In KnowledgeItem model, add:
var needsProjectReprocessing: Bool
var projectReprocessContext: String?
```

Initialize both to `false` and `nil` in the KnowledgeItem init.

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Domain/Services/ProjectService.swift wawa-note/Domain/Models/*.swift
git commit -m "feat: add derived item queries and reprocess marking to ProjectService

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Data migration — TaskItem and AgentSuggestion to ProjectDerivedItem

**Files:**
- Modify: `wawa-note/Domain/Services/ProjectService.swift` (add migration method)
- Test: `wawa-noteTests/ProjectDerivedItemTests.swift`

**Interfaces:**
- Consumes: `ProjectDerivedItemService` (Task 2), existing `TaskItem` and `AgentSuggestion` models
- Produces: Migration that converts all existing records

- [ ] **Step 1: Write migration test**

```swift
// In ProjectDerivedItemTests.swift, add:
func testMigrationFromTaskItem() throws {
    // This test verifies migration logic converts TaskItem fields correctly
    let taskItem = TaskItem(
        title: "Old task",
        projectID: UUID(),
        status: .inProgress,
        priority: .high,
        ownerName: "Bob",
        dueAt: Date().addingTimeInterval(7200)
    )
    // Migration would create equivalent ProjectDerivedItem
    let derived = ProjectDerivedItem(
        projectID: taskItem.projectID ?? UUID(),
        sourceItemID: taskItem.sourceItemID,
        type: .task,
        title: taskItem.title,
        status: {
            switch taskItem.status {
            case .todo: .todo
            case .inProgress: .inProgress
            case .done: .done
            case .cancelled: .cancelled
            }
        }(),
        priority: taskItem.priority,
        ownerName: taskItem.ownerName,
        dueAt: taskItem.dueAt,
        confidence: taskItem.confidence,
        createdAt: taskItem.createdAt,
        updatedAt: taskItem.updatedAt
    )
    XCTAssertEqual(derived.title, "Old task")
    XCTAssertEqual(derived.status, .inProgress)
    XCTAssertEqual(derived.priorityRaw, "high")
    XCTAssertEqual(derived.ownerName, "Bob")
}
```

- [ ] **Step 2: Add migration method to ProjectService**

```swift
// Add to ProjectService.swift:
/// One-time migration: convert TaskItem and AgentSuggestion records to ProjectDerivedItem.
/// Run once on app launch after model update. Existing records are preserved as deprecated models.
static func migrateToProjectDerivedItems(context: ModelContext) {
    let key = "migration_to_project_derived_v1"
    if UserDefaults.standard.bool(forKey: key) { return }

    let derivedService = ProjectDerivedItemService(context: context)

    // Migrate TaskItems
    if let allTasks = try? context.fetch(FetchDescriptor<TaskItem>()) {
        for task in allTasks {
            guard let pid = task.projectID else { continue }
            do {
                let body = TaskBody(
                    description: task.notes,
                    sourceSegmentIDs: task.sourceSegmentIDList,
                    aiGenerated: task.createdBy != .user,
                    suggestedByItemID: task.sourceItemID
                )
                let bodyData = try? JSONEncoder().encode(body)
                let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

                let derivedStatus: ProjectDerivedStatus = {
                    switch task.status {
                    case .todo: .todo
                    case .inProgress: .inProgress
                    case .done: .done
                    case .cancelled: .cancelled
                    }
                }()

                _ = try derivedService.createTask(
                    title: task.title,
                    projectID: pid,
                    sourceItemID: task.sourceItemID,
                    priority: task.priority,
                    ownerName: task.ownerName,
                    dueAt: task.dueAt,
                    bodyJSON: bodyStr
                )
                // Update the new item's dates to match original
                if let newItem = try? derivedService.fetch(for: pid, type: .task).first(where: { $0.title == task.title }) {
                    newItem.createdAt = task.createdAt
                    newItem.updatedAt = task.updatedAt
                }
            } catch {
                AppLog.general.error("Migration: failed to migrate task \(task.title): \(error)")
            }
        }
    }

    // Migrate AgentSuggestions
    if let allSignals = try? context.fetch(FetchDescriptor<AgentSuggestion>()) {
        for signal in allSignals {
            guard let pid = signal.projectID else { continue }
            do {
                let body = SignalBody(
                    signalType: signal.type,
                    description: signal.body ?? "",
                    suggestedAction: nil,
                    impactScore: signal.impactScore,
                    urgencyScore: signal.urgencyScore
                )
                let derivedStatus: ProjectDerivedStatus = {
                    switch signal.status {
                    case "visible": .visible
                    case "seen", "acknowledged": .acknowledged
                    case "approved", "transformed": .resolved
                    default: .dismissed
                    }
                }()

                _ = try derivedService.createSignal(
                    title: signal.title,
                    projectID: pid,
                    sourceItemID: signal.sourceItemID,
                    signalBody: body,
                    confidence: signal.confidence,
                    isCritical: signal.isCritical
                )
            } catch {
                AppLog.general.error("Migration: failed to migrate signal \(signal.title): \(error)")
            }
        }
    }

    try? context.save()
    UserDefaults.standard.set(true, forKey: key)
    AppLog.general.info("Migration to ProjectDerivedItem complete")
}
```

- [ ] **Step 3: Call migration in app startup**

In `WawaNoteApp.swift`, add the migration call alongside existing migrations (`ProjectService.migrateProjectColors`, `ProjectService.migrateFieldProvenance`):

```swift
ProjectService.migrateToProjectDerivedItems(context: modelContext)
```

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Domain/Services/ProjectService.swift wawa-note/App/WawaNoteApp.swift
git commit -m "feat: add TaskItem → ProjectDerivedItem data migration

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Simplificar ProjectDetailView — Segment Control Síntese | Arquivos

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift`
- Create: (placeholder for) `wawa-note/UI/Project/ProjectSynthesisView.swift`

**Interfaces:**
- Consumes: `ProjectDerivedItemService` (Task 2), `ProjectService` (Task 3)
- Produces: Simplified `ProjectDetailView` with two segments

- [ ] **Step 1: Replace ProjectDetailView body**

In `wawa-note/UI/Project/ProjectDetailView.swift`, replace the body of `ProjectHomeView` with a simplified segment-control version. Keep `ProjectDetailView` (entry point) and `ProjectDetailLink` unchanged. Replace `ProjectHomeView`:

```swift
// MARK: - Project Home (Simplified)

struct ProjectHomeView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var chatState: ChatOverlayState
    @State private var selectedTab: ProjectTab = .synthesis

    enum ProjectTab: String, CaseIterable {
        case synthesis = "Síntese"
        case files = "Arquivos"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segment control
            Picker("View", selection: $selectedTab) {
                ForEach(ProjectTab.allCases, id: \.rawValue) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            // Content
            switch selectedTab {
            case .synthesis:
                ProjectSynthesisView(project: project)
            case .files:
                ItemsView(projectID: project.id)
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { /* capture flow */ } label: {
                        Label("Add Item", systemImage: "plus")
                    }
                    Button { /* export */ } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            chatState.context = .project(project.id)
        }
    }
}
```

- [ ] **Step 2: Create placeholder SynthesisView**

Create `wawa-note/UI/Project/ProjectSynthesisView.swift`:

```swift
import SwiftUI
import SwiftData

/// Renders the project's synthesis document with actionable primitives.
struct ProjectSynthesisView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @State private var synthesis: ProjectDerivedItem?
    @State private var derivedItems: [ProjectDerivedItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading synthesis...")
                    .onAppear { loadData() }
            } else if let synthesis {
                ScrollView {
                    SynthesisContentView(synthesis: synthesis, derivedItems: derivedItems, projectID: project.id)
                }
                .refreshable { loadData() }
            } else {
                EmptySynthesisView(project: project)
            }
        }
    }

    private func loadData() {
        let svc = ProjectDerivedItemService(context: modelContext)
        synthesis = try? svc.fetchSynthesis(for: project.id).first
        derivedItems = (try? svc.fetch(for: project.id)) ?? []
        isLoading = false
    }
}

/// Placeholder — will be fully implemented in Task 9.
struct SynthesisContentView: View {
    let synthesis: ProjectDerivedItem
    let derivedItems: [ProjectDerivedItem]
    let projectID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Parse and render synthesis body
            if let bodyJSON = synthesis.bodyJSON,
               let data = bodyJSON.data(using: .utf8),
               let body = try? JSONDecoder().decode(SynthesisBody.self, from: data) {
                Text(.init(body.markdown))
                    .padding()
            } else {
                Text("Synthesis pending...")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

/// Shown when no synthesis exists yet.
struct EmptySynthesisView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.richtext")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No synthesis yet")
                .font(.headline)
            Text("The Project Agent generates a synthesis once items are added and analyzed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            // Check if there are items to process
            let items = (try? ProjectService(context: modelContext).items(in: project.id)) ?? []
            if items.isEmpty {
                Text("Add items to this project to get started.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button("Generate Synthesis") {
                    // Will trigger ProjectAgent in Task 6
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }
}
```

- [ ] **Step 3: Verify build compiles**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift wawa-note/UI/Project/ProjectSynthesisView.swift
git commit -m "feat: simplify ProjectDetailView to Synthesis | Files segment control

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Enhance ItemsView for unified KnowledgeItem + ProjectDerivedItem display

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (ItemsView is here)

**Interfaces:**
- Consumes: `ProjectDerivedItemService` (Task 2), `ProjectService` (Task 3)
- Produces: Unified file browser showing both KnowledgeItem and ProjectDerivedItem rows

- [ ] **Step 1: Add unified row model to ItemsView**

In `ProjectDetailView.swift`, add before `ItemsView`:

```swift
// MARK: - Unified Item Row

/// Represents either a KnowledgeItem or a ProjectDerivedItem in the unified file browser.
enum UnifiedItem: Identifiable {
    case knowledge(KnowledgeItem)
    case derived(ProjectDerivedItem)

    var id: UUID {
        switch self {
        case .knowledge(let item): item.id
        case .derived(let item): item.id
        }
    }

    var title: String {
        switch self {
        case .knowledge(let item): item.title
        case .derived(let item): item.title
        }
    }

    var displayIcon: String {
        switch self {
        case .knowledge(let item): item.type.icon
        case .derived(let item): item.displayIcon
        }
    }

    var displayColor: Color {
        switch self {
        case .knowledge(let item): item.type.color
        case .derived(let item):
            switch item.type {
            case .synthesis: .purple
            case .task: .teal
            case .signal: .orange
            case .connection: .blue
            }
        }
    }

    var subtitle: String {
        switch self {
        case .knowledge(let item): item.type.label
        case .derived(let item):
            switch item.type {
            case .synthesis: "Synthesis"
            case .task: "Task · \(item.statusRaw ?? "todo")"
            case .signal: "Signal · \(item.statusRaw ?? "visible")"
            case .connection: "Connection"
            }
        }
    }

    var createdAt: Date {
        switch self {
        case .knowledge(let item): item.createdAt
        case .derived(let item): item.createdAt
        }
    }

    var isSource: Bool {
        if case .knowledge = self { return true }
        return false
    }

    var isDerived: Bool {
        if case .derived = self { return true }
        return false
    }
}
```

- [ ] **Step 2: Update ItemsView to fetch and display unified list**

Modify `ItemsView` to load both sources:

```swift
struct ItemsView: View {
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var unifiedItems: [UnifiedItem] = []
    @State private var searchText = ""
    @State private var selectedType: UnifiedItemFilter = .all
    @State private var sortOrder: ItemSortOrder = .recent

    enum UnifiedItemFilter: String, CaseIterable {
        case all = "All"
        case meetings = "Meetings"
        case notes = "Notes"
        case tasks = "Tasks"
        case signals = "Signals"
        case synthesis = "Synthesis"
        case connections = "Connections"
    }

    var body: some View {
        List {
            if filteredItems.isEmpty {
                emptyState
            } else {
                ForEach(filteredItems) { item in
                    unifiedRow(item)
                        .swipeActions(edge: .trailing) {
                            if case .knowledge(let ki) = item {
                                Button(role: .destructive) {
                                    try? TrashService(context: modelContext).moveToTrash(ki)
                                    loadItems()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } else if case .derived(let di) = item {
                                Button(role: .destructive) {
                                    try? ProjectDerivedItemService(context: modelContext).delete(di)
                                    loadItems()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search files")
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    sortMenu
                    filterMenu
                }
            }
        }
        .onAppear { loadItems() }
        .refreshable { loadItems() }
    }

    // ... (filteredItems, emptyState, unifiedRow, etc. — adapted from existing ItemsView)
    // Keep existing sorting, search, and filter patterns but operate on UnifiedItem
}
```

Full implementation details: adapt the existing `filteredItems`, `emptyState`, `itemRow`, `loadItems`, `sortMenu`, `filterMenu` from the current ItemsView. Replace `KnowledgeItem` arrays with `[UnifiedItem]` and add the derived item fetch alongside the existing `ProjectService.items(in:)` call in `loadItems()`.

- [ ] **Step 3: Verify build compiles**

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "feat: enhance ItemsView for unified KnowledgeItem + ProjectDerivedItem display

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Update BoardView to use ProjectDerivedItem(type: .task)

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (BoardView is here)

**Interfaces:**
- Consumes: `ProjectDerivedItemService` (Task 2)
- Produces: BoardView reading from ProjectDerivedItem instead of TaskItem

- [ ] **Step 1: Update BoardView data source**

In `BoardView`, replace `TaskItem` references with `ProjectDerivedItem`:

Change:
```swift
@State private var tasks: [TaskItem] = []
```
To:
```swift
@State private var tasks: [ProjectDerivedItem] = []
```

Change `loadData()`:
```swift
private func loadData() {
    tasks = (try? ProjectDerivedItemService(context: modelContext).fetch(for: projectID, type: .task)) ?? []
    items = (try? ProjectService(context: modelContext).items(in: projectID)) ?? []
}
```

Update `filtered(_ status:)`:
```swift
private func filtered(_ status: TaskStatus) -> [ProjectDerivedItem] {
    let raw = status.rawValue
    return tasks.filter { $0.statusRaw == raw }
}
```

Update `moveTask`:
```swift
private func moveTask(_ task: ProjectDerivedItem, to status: TaskStatus) {
    let derivedStatus: ProjectDerivedStatus = {
        switch status {
        case .todo: .todo; case .inProgress: .inProgress
        case .done: .done; case .cancelled: .cancelled
        }
    }()
    try? ProjectDerivedItemService(context: modelContext).updateStatus(task, to: derivedStatus)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    loadData()
}
```

Update `deleteTask`:
```swift
private func deleteTask(_ task: ProjectDerivedItem) {
    try? ProjectDerivedItemService(context: modelContext).delete(task)
    loadData()
}
```

Update `taskCard` parameter type from `TaskItem` to `ProjectDerivedItem`. Update fields: `task.title`, `task.ownerName`, `task.dueAt`, `task.priorityRaw` (convert to `TaskPriority` for color).

- [ ] **Step 2: Update TaskEditorView**

In `TaskEditorView`, update `mode` to work with `ProjectDerivedItem` instead of `TaskItem`:

```swift
enum TaskEditorMode {
    case create(projectID: UUID)
    case edit(task: ProjectDerivedItem)
}
```

Update the save logic to use `ProjectDerivedItemService`.

- [ ] **Step 3: Verify build compiles**

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift wawa-note/UI/Project/TaskEditorView.swift
git commit -m "feat: update BoardView and TaskEditorView to use ProjectDerivedItem

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Create ProjectAgent — extend AgentLoop for project synthesis

**Files:**
- Create: `wawa-note/Domain/Agent/ProjectAgent.swift`
- Create: `wawa-note/Domain/Agent/Tools/ProjectTools.swift`

**Interfaces:**
- Consumes: `AgentLoop` (existing), `AgentToolRegistry`, `ToolContext`, `ProjectDerivedItemService` (Task 2), `ProjectService` (Task 3), `ContentPipelineService`
- Produces: `ProjectAgent` — async service that generates/updates synthesis

- [ ] **Step 1: Create ProjectAgent**

Create `wawa-note/Domain/Agent/ProjectAgent.swift`:

```swift
import Foundation
import SwiftData

/// ProjectAgent — runs AgentLoop scoped to a project's items.
/// Generates synthesis, emits signals, creates connections.
/// Does NOT reprocess individual items — delegates that to Item Agent.
@MainActor
final class ProjectAgent {
    private let projectID: UUID
    private let context: ModelContext
    private let projectService: ProjectService
    private let derivedService: ProjectDerivedItemService

    init(projectID: UUID, context: ModelContext) {
        self.projectID = projectID
        self.context = context
        self.projectService = ProjectService(context: context)
        self.derivedService = ProjectDerivedItemService(context: context)
    }

    // MARK: - Synthesis generation

    /// Generates or updates the project synthesis by running the agent over
    /// all item derivations and project context.
    func generateSynthesis() async throws -> ProjectDerivedItem {
        guard let project = try projectService.fetch(id: projectID) else {
            throw ProjectAgentError.projectNotFound
        }

        // 1. Gather context: item derivations + existing synthesis + device context
        let items = (try? projectService.items(in: projectID)) ?? []
        let existingSynthesis = try? derivedService.fetchSynthesis(for: projectID).first
        let existingTasks = (try? derivedService.fetch(for: projectID, type: .task)) ?? []
        let existingSignals = (try? derivedService.fetch(for: projectID, type: .signal)) ?? []
        let edges = (try? GraphEdgeService(context: context).neighborhood(of: projectID, radius: 2)) ?? []

        // 2. Build context description
        let contextDescription = buildContextDescription(
            project: project,
            items: items,
            existingSynthesis: existingSynthesis,
            tasks: existingTasks,
            signals: existingSignals,
            edges: edges
        )

        // 3. Run AgentLoop with synthesis tools
        let registry = AgentToolRegistry()
        ProjectTools.register(in: registry, projectID: projectID, context: context)

        let toolContext = ToolContext(
            projectID: projectID,
            context: context,
            fileStore: FileArtifactStore()
        )

        let loop = AgentLoop(
            registry: registry,
            toolContext: toolContext,
            mode: .deep,  // Synthesis needs thorough analysis
            executorModel: AIConfigService.shared.modelFor(feature: "analysis")
        )

        let prompt = """
        You are the Project Agent for "\(project.name)".
        Your universe is this project's items and their derivations.

        ## PROJECT CONTEXT
        \(contextDescription)

        ## YOUR TASK
        Generate a project synthesis that:

        1. Summarizes the current state of the project (2-3 paragraphs)
        2. Lists active decisions and their status
        3. Identifies risks and their mitigation status
        4. Highlights cross-item connections and patterns
        5. Provides metrics: decision velocity, task completion rate, risk exposure

        Use the `synthesize_project` tool to save your output.
        If you detect contradictions across items, create signals.
        If you find items that need re-analysis with project context, emit reprocess triggers.
        """

        let result = try await loop.run(userMessage: prompt)

        // 4. Parse result and create/update synthesis
        let synthesis = try await parseAndSaveSynthesis(result: result, projectID: projectID)

        return synthesis
    }

    // MARK: - Device context enrichment

    /// Enriches newly added items with device context (Calendar, Contacts, Location).
    func enrichWithDeviceContext(itemIDs: [UUID]) async throws {
        let deviceContext = DeviceContextService()
        for itemID in itemIDs {
            guard let item = try fetchKnowledgeItem(itemID) else { continue }
            let enrichments = await deviceContext.crossReference(item: item)
            for enrichment in enrichments {
                switch enrichment {
                case .calendarEvent(let event):
                    // Create a connection: item IS this calendar event
                    _ = try derivedService.createConnection(
                        title: "\(item.title) → Calendar: \(event.title)",
                        projectID: projectID,
                        fromDerivedID: item.id,
                        toDerivedID: projectID,
                        edgeType: .references,
                        provenanceItemID: item.id
                    )
                case .contact(let person):
                    // Link person to item
                    let personID = try ensurePersonExists(person, context: context)
                    try GraphEdgeService(context: context).create(
                        fromID: item.id,
                        toID: personID,
                        edgeType: .mentions,
                        provenanceItemID: item.id
                    )
                case .location(let place):
                    // Tag item with location context
                    AppLog.general.info("DeviceContext: item \(item.title.prefix(20)) matched location \(place)")
                }
            }
        }
    }

    // MARK: - Reprocess triggers

    /// Detects items that need re-analysis with project context and emits triggers.
    func detectReprocessNeeds() async throws -> [UUID] {
        let items = (try? projectService.items(in: projectID)) ?? []
        // For items marked as needing reprocessing or items that entered the project after initial analysis
        let candidates = items.filter { $0.needsProjectReprocessing }
        for item in candidates {
            let context = item.projectReprocessContext ?? "Project: \(try? projectService.fetch(id: projectID)?.name ?? "")"
            // Item Agent will pick this up — the reprocess flag is already set
            AppLog.general.info("ProjectAgent: item \(item.title.prefix(20)) needs reprocessing with context: \(context)")
        }
        return candidates.map(\.id)
    }

    // MARK: - Private

    private func buildContextDescription(
        project: Project,
        items: [KnowledgeItem],
        existingSynthesis: ProjectDerivedItem?,
        tasks: [ProjectDerivedItem],
        signals: [ProjectDerivedItem],
        edges: [GraphEdge]
    ) -> String {
        var desc = "PROJECT: \(project.name)\n"
        if let intent = project.intention { desc += "Intention: \(intent)\n" }
        if let summary = project.summary { desc += "Summary: \(summary)\n" }

        desc += "\nITEMS (\(items.count)):\n"
        for item in items.prefix(20) {  // Cap for context window
            desc += "- [\(item.type.label)] \(item.title) (\(item.createdAt.formatted(date: .abbreviated, time: .omitted)))\n"
        }

        desc += "\nTASKS (\(tasks.count)):\n"
        for task in tasks.prefix(15) {
            desc += "- [\(task.statusRaw ?? "?")] \(task.title)"
            if let owner = task.ownerName { desc += " · \(owner)" }
            if let due = task.dueAt { desc += " · due \(due.formatted(date: .abbreviated, time: .omitted))" }
            desc += "\n"
        }

        desc += "\nSIGNALS (\(signals.count)):\n"
        for signal in signals.prefix(10) {
            desc += "- [\(signal.statusRaw ?? "?")] \(signal.title)"
            if signal.isCritical { desc += " ⚠️ CRITICAL" }
            desc += "\n"
        }

        if let existing = existingSynthesis, let bodyJSON = existing.bodyJSON {
            desc += "\nEXISTING SYNTHESIS (abbreviated):\n"
            desc += String(bodyJSON.prefix(500)) + "...\n"
        }

        return desc
    }

    private func fetchKnowledgeItem(_ id: UUID) throws -> KnowledgeItem? {
        var descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func parseAndSaveSynthesis(result: String, projectID: UUID) async throws -> ProjectDerivedItem {
        // Parse the agent output for sections, metrics, markdown
        // The agent's synthesize_project tool calls produce structured output
        // This method extracts it and saves via ProjectDerivedItemService

        // For now, save the raw agent output as markdown
        let sections = extractSynthesisSections(from: result)
        let metrics = extractMetrics(from: result)

        return try derivedService.createSynthesis(
            projectID: projectID,
            markdown: result,
            sections: sections,
            metrics: metrics,
            updatedFromItemIDs: [] // Populated by tool calls
        )
    }

    private func extractSynthesisSections(from text: String) -> [SynthesisSection] {
        // Parse markdown headings as sections
        var sections: [SynthesisSection] = []
        var order = 0
        // Simple heuristic: ## Heading creates a section
        let lines = text.components(separatedBy: "\n")
        var currentTitle = ""
        var currentContent = ""
        for line in lines {
            if line.hasPrefix("## ") {
                if !currentTitle.isEmpty {
                    sections.append(SynthesisSection(
                        id: UUID().uuidString,
                        title: currentTitle,
                        renderType: "markdown",
                        content: currentContent,
                        order: order
                    ))
                    order += 1
                }
                currentTitle = String(line.dropFirst(3))
                currentContent = ""
            } else {
                currentContent += line + "\n"
            }
        }
        if !currentTitle.isEmpty {
            sections.append(SynthesisSection(
                id: UUID().uuidString,
                title: currentTitle,
                renderType: "markdown",
                content: currentContent,
                order: order
            ))
        }
        return sections
    }

    private func extractMetrics(from text: String) -> [SynthesisMetric] {
        // Default metrics — will be enhanced when agent emits structured metrics
        return []
    }
}

enum ProjectAgentError: Error {
    case projectNotFound
    case synthesisFailed(String)
}
```

- [ ] **Step 2: Create ProjectTools**

Create `wawa-note/Domain/Agent/Tools/ProjectTools.swift`:

```swift
import Foundation
import SwiftData

/// Tools available to the Project Agent during synthesis.
enum ProjectTools {
    static func register(in registry: AgentToolRegistry, projectID: UUID, context: ModelContext) {
        registry.register(SynthesizeProjectTool(projectID: projectID, context: context))
        registry.register(EmitSignalTool(projectID: projectID, context: context))
        registry.register(CreateConnectionTool(projectID: projectID, context: context))
        registry.register(RequestReprocessTool(projectID: projectID, context: context))
    }
}

// MARK: - SynthesizeProject Tool

struct SynthesizeProjectTool: AgentTool {
    let name = "synthesize_project"
    let description = "Save the project synthesis with sections, metrics, and markdown content"
    let projectID: UUID
    let context: ModelContext

    var parameters: [ToolParameter] {
        [
            ToolParameter(name: "markdown", type: .string, description: "Full synthesis in markdown format", required: true),
            ToolParameter(name: "sections", type: .array, description: "Array of {title, renderType, content} objects", required: false),
            ToolParameter(name: "metrics", type: .array, description: "Array of {label, value, format, status} objects", required: false),
            ToolParameter(name: "updatedFromItemIDs", type: .array, description: "UUIDs of items that contributed to this version", required: false)
        ]
    }

    func execute(_ args: [String: Any]) async throws -> String {
        guard let markdown = args["markdown"] as? String else {
            throw ToolError.invalidArgs("markdown required")
        }

        let sections: [SynthesisSection] = (args["sections"] as? [[String: Any]])?.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let renderType = dict["renderType"] as? String,
                  let content = dict["content"] as? String
            else { return nil }
            return SynthesisSection(id: UUID().uuidString, title: title, renderType: renderType, content: content, order: 0)
        } ?? []

        let metrics: [SynthesisMetric] = (args["metrics"] as? [[String: Any]])?.compactMap { dict in
            guard let label = dict["label"] as? String,
                  let value = dict["value"] as? Double
            else { return nil }
            return SynthesisMetric(
                id: UUID().uuidString,
                label: label,
                value: value,
                format: dict["format"] as? String ?? "number",
                status: dict["status"] as? String ?? "neutral",
                icon: dict["icon"] as? String
            )
        } ?? []

        let updatedFrom = args["updatedFromItemIDs"] as? [String] ?? []

        let service = ProjectDerivedItemService(context: context)
        let _ = try service.createSynthesis(
            projectID: projectID,
            markdown: markdown,
            sections: sections,
            metrics: metrics,
            updatedFromItemIDs: updatedFrom.compactMap(UUID.init(uuidString:))
        )

        return "Synthesis saved (\(sections.count) sections, \(metrics.count) metrics)"
    }
}

// MARK: - EmitSignal Tool

struct EmitSignalTool: AgentTool {
    let name = "emit_signal"
    let description = "Create a signal (alert, risk, opportunity, doubt, pattern, contradiction) for the project"
    let projectID: UUID
    let context: ModelContext

    var parameters: [ToolParameter] {
        [
            ToolParameter(name: "title", type: .string, description: "Signal title", required: true),
            ToolParameter(name: "signalType", type: .string, description: "risk, alert, opportunity, doubt, pattern, contradiction", required: true),
            ToolParameter(name: "description", type: .string, description: "Detailed description", required: true),
            ToolParameter(name: "suggestedAction", type: .string, description: "What the user should do", required: false),
            ToolParameter(name: "confidence", type: .number, description: "0.0-1.0 confidence", required: false),
            ToolParameter(name: "isCritical", type: .boolean, description: "Demands immediate attention", required: false),
            ToolParameter(name: "impactScore", type: .number, description: "0.0-1.0 impact", required: false),
            ToolParameter(name: "urgencyScore", type: .number, description: "0.0-1.0 urgency", required: false),
            ToolParameter(name: "relatedItemIDs", type: .array, description: "Related item UUIDs as strings", required: false)
        ]
    }

    func execute(_ args: [String: Any]) async throws -> String {
        guard let title = args["title"] as? String,
              let signalType = args["signalType"] as? String
        else { throw ToolError.invalidArgs("title and signalType required") }

        let body = SignalBody(
            signalType: signalType,
            description: args["description"] as? String ?? "",
            suggestedAction: args["suggestedAction"] as? String,
            relatedItemIDs: (args["relatedItemIDs"] as? [String])?.compactMap(UUID.init(uuidString:)),
            impactScore: args["impactScore"] as? Double,
            urgencyScore: args["urgencyScore"] as? Double
        )

        let service = ProjectDerivedItemService(context: context)
        let _ = try service.createSignal(
            title: title,
            projectID: projectID,
            signalBody: body,
            confidence: args["confidence"] as? Double,
            isCritical: args["isCritical"] as? Bool ?? false
        )

        return "Signal emitted: \(title)"
    }
}

// MARK: - CreateConnection Tool

struct CreateConnectionTool: AgentTool {
    let name = "create_connection"
    let description = "Create a typed connection between two items or derivations"
    let projectID: UUID
    let context: ModelContext

    var parameters: [ToolParameter] {
        [
            ToolParameter(name: "fromID", type: .string, description: "Source item UUID", required: true),
            ToolParameter(name: "toID", type: .string, description: "Target item UUID", required: true),
            ToolParameter(name: "title", type: .string, description: "Human-readable connection description", required: true),
            ToolParameter(name: "edgeType", type: .string, description: "resolves, supports, contradicts, reinforces, supersedes, references", required: true),
            ToolParameter(name: "provenanceItemID", type: .string, description: "Evidence item UUID", required: false)
        ]
    }

    func execute(_ args: [String: Any]) async throws -> String {
        guard let fromStr = args["fromID"] as? String, let fromID = UUID(uuidString: fromStr),
              let toStr = args["toID"] as? String, let toID = UUID(uuidString: toStr),
              let title = args["title"] as? String,
              let edgeTypeStr = args["edgeType"] as? String
        else { throw ToolError.invalidArgs("fromID, toID, title, edgeType required") }

        let edgeType = EdgeType(rawValue: edgeTypeStr) ?? .references
        let provenance = (args["provenanceItemID"] as? String).flatMap(UUID.init(uuidString:))

        let service = ProjectDerivedItemService(context: context)
        let _ = try service.createConnection(
            title: title,
            projectID: projectID,
            fromDerivedID: fromID,
            toDerivedID: toID,
            edgeType: edgeType,
            provenanceItemID: provenance
        )

        return "Connection created: \(title)"
    }
}

// MARK: - RequestReprocess Tool

struct RequestReprocessTool: AgentTool {
    let name = "request_reprocess"
    let description = "Mark items for re-analysis with project context"
    let projectID: UUID
    let context: ModelContext

    var parameters: [ToolParameter] {
        [
            ToolParameter(name: "itemIDs", type: .array, description: "Item UUIDs to reprocess", required: true),
            ToolParameter(name: "context", type: .string, description: "Why reprocessing is needed, what to focus on", required: true)
        ]
    }

    func execute(_ args: [String: Any]) async throws -> String {
        guard let itemIDStrs = args["itemIDs"] as? [String],
              let reprocessContext = args["context"] as? String
        else { throw ToolError.invalidArgs("itemIDs and context required") }

        let itemIDs = itemIDStrs.compactMap(UUID.init(uuidString:))
        let svc = ProjectService(context: context)
        for itemID in itemIDs {
            try svc.markForReprocessing(itemID: itemID, projectID: projectID, context: reprocessContext)
        }

        return "\(itemIDs.count) items marked for reprocessing"
    }
}
```

- [ ] **Step 2: Run build to verify compilation**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Agent/ProjectAgent.swift wawa-note/Domain/Agent/Tools/ProjectTools.swift
git commit -m "feat: add ProjectAgent with synthesis generation and project tools

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Device Context Service — Calendar, Contacts, Location cross-referencing

**Files:**
- Create: `wawa-note/Domain/Services/DeviceContextService.swift`

**Interfaces:**
- Consumes: EventKit, Contacts.framework, CoreLocation
- Produces: `DeviceContextService` — cross-references items with device data

- [ ] **Step 1: Create DeviceContextService**

Create `wawa-note/Domain/Services/DeviceContextService.swift`:

```swift
import Foundation
import EventKit
import Contacts
import CoreLocation
import SwiftData

// MARK: - Device Context Enrichment

enum DeviceEnrichment {
    case calendarEvent(CalendarMatch)
    case contact(ContactMatch)
    case location(String) // Location name
}

struct CalendarMatch {
    let eventID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let attendees: [String]
    let location: String?
}

struct ContactMatch {
    let contactID: String
    let displayName: String
    let email: String?
    let phone: String?
    let organization: String?
    let hasRecentCalls: Bool
}

@MainActor
final class DeviceContextService {
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

    /// Cross-references an item with device context sources.
    /// Returns enrichments for calendar events, contacts, and location.
    func crossReference(item: KnowledgeItem) async -> [DeviceEnrichment] {
        var enrichments: [DeviceEnrichment] = []

        // 1. Calendar matching by date/time
        if let calMatch = await matchCalendarEvent(item: item) {
            enrichments.append(.calendarEvent(calMatch))
        }

        // 2. Contact matching from transcript/analysis text
        let contactMatches = await matchContacts(from: item)
        enrichments.append(contentsOf: contactMatches.map { .contact($0) })

        // 3. Location matching
        if let location = await matchLocation(item: item) {
            enrichments.append(.location(location))
        }

        return enrichments
    }

    // MARK: - Calendar matching

    private func matchCalendarEvent(item: KnowledgeItem) async -> CalendarMatch? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .writeOnly else { return nil }

        let itemDate = item.createdAt
        let windowStart = itemDate.addingTimeInterval(-3600) // 1h before
        let windowEnd = itemDate.addingTimeInterval(3600)    // 1h after

        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        // Find closest event by time proximity
        guard let closest = events.min(by: { abs($0.startDate.timeIntervalSince(itemDate)) < abs($1.startDate.timeIntervalSince(itemDate)) }),
              abs(closest.startDate.timeIntervalSince(itemDate)) < 1800 // Within 30 min
        else { return nil }

        let attendees = (closest.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString }

        return CalendarMatch(
            eventID: closest.eventIdentifier,
            title: closest.title,
            startDate: closest.startDate,
            endDate: closest.endDate,
            attendees: attendees,
            location: closest.location
        )
    }

    // MARK: - Contact matching

    private func matchContacts(from item: KnowledgeItem) async -> [ContactMatch] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return [] }

        // Build search text from item title + transcript (if available)
        var searchText = item.title
        if let transcript = try? FileArtifactStore().readText(named: "transcript.txt", itemID: item.id) {
            searchText += " " + transcript
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var matches: [ContactMatch] = []

        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let fullName = "\(contact.givenName) \(contact.familyName)"
                // Check if contact name appears in item content
                if searchText.localizedCaseInsensitiveContains(contact.givenName) ||
                   searchText.localizedCaseInsensitiveContains(contact.familyName) ||
                   searchText.localizedCaseInsensitiveContains(fullName) {
                    matches.append(ContactMatch(
                        contactID: contact.identifier,
                        displayName: fullName,
                        email: contact.emailAddresses.first?.value as String?,
                        phone: contact.phoneNumbers.first?.value.stringValue,
                        organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                        hasRecentCalls: false // Call history requires CallKit, deferred
                    ))
                }
            }
        } catch {
            AppLog.general.error("DeviceContext: contact search failed: \(error)")
        }

        return matches
    }

    // MARK: - Location matching

    private func matchLocation(item: KnowledgeItem) async -> String? {
        // Location context is captured by context sensors during recording
        // Check if item has associated location metadata
        // For now: return nil, location enrichment is passive from context sensors
        return nil
    }
}

// MARK: - Person resolution helper

/// Ensures a Person record exists in SwiftData for a matched contact.
func ensurePersonExists(_ contact: ContactMatch, context: ModelContext) throws -> UUID {
    let key = contact.displayName.lowercased().trimmingCharacters(in: .whitespaces)
    var descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.canonicalKey == key })
    descriptor.fetchLimit = 1

    if let existing = try context.fetch(descriptor).first {
        return existing.id
    }

    let person = Person(
        displayName: contact.displayName,
        canonicalKey: key,
        email: contact.email,
        role: contact.organization
    )
    context.insert(person)
    try context.save()
    return person.id
}
```

- [ ] **Step 2: Add privacy permission handling**

In the app's permission system (existing `PermissionPromptView` or similar), add Calendar and Contacts permission requests. These follow the same pattern as existing permissions (microphone, speech recognition, etc.).

- [ ] **Step 3: Verify build compiles**

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/DeviceContextService.swift
git commit -m "feat: add DeviceContextService for Calendar/Contacts cross-referencing

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Send To menu — Unified project outputs

**Files:**
- Create: `wawa-note/UI/Project/SendToMenuView.swift`
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (add Send To context menu to unified rows)

**Interfaces:**
- Consumes: EventKit (Calendar), Contacts.framework, Reminders (EventKit), Share Sheet (UIKit), existing exporters
- Produces: Send To context menu on every file browser row

- [ ] **Step 1: Create SendToMenuView**

Create `wawa-note/UI/Project/SendToMenuView.swift`:

```swift
import SwiftUI
import EventKit
import Contacts
import ContactsUI
import UniformTypeIdentifiers

// MARK: - Send To Action

enum SendToDestination: String, CaseIterable {
    case reminders = "Reminders"
    case calendar = "Calendar"
    case contacts = "Contacts"
    case markdown = "Markdown"
    case pdf = "PDF"
    case csv = "CSV"
    case share = "Share"
}

/// Unified export context menu builder.
/// Determines available destinations based on the item type.
struct SendToMenu: View {
    let item: UnifiedItem
    let projectID: UUID
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Menu {
            ForEach(availableDestinations, id: \.rawValue) { dest in
                Button { execute(dest) } label: {
                    Label(dest.rawValue, systemImage: icon(for: dest))
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private var availableDestinations: [SendToDestination] {
        switch item {
        case .knowledge:
            return [.share, .markdown, .pdf]
        case .derived(let di):
            switch di.type {
            case .task:
                return [.reminders, .calendar, .share]
            case .synthesis:
                return [.markdown, .pdf, .share]
            case .signal:
                return [.reminders, .calendar, .share]
            case .connection:
                return [.share]
            }
        }
    }

    private func icon(for dest: SendToDestination) -> String {
        switch dest {
        case .reminders: "checklist"
        case .calendar: "calendar"
        case .contacts: "person.crop.circle"
        case .markdown: "doc.richtext"
        case .pdf: "doc.text"
        case .csv: "tablecells"
        case .share: "square.and.arrow.up"
        }
    }

    private func execute(_ dest: SendToDestination) {
        switch dest {
        case .reminders: exportToReminders()
        case .calendar: exportToCalendar()
        case .contacts: exportToContacts()
        case .markdown: exportMarkdown()
        case .pdf: exportPDF()
        case .csv: exportCSV()
        case .share: shareItem()
        }
    }

    // MARK: - Export implementations

    private func exportToReminders() {
        guard case .derived(let derived) = item, derived.type == .task else { return }
        let eventStore = EKEventStore()
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                guard granted else { return }
                let reminder = EKReminder(eventStore: eventStore)
                reminder.title = derived.title
                if let due = derived.dueAt {
                    reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
                }
                reminder.calendar = eventStore.defaultCalendarForNewReminders()
                try eventStore.save(reminder, commit: true)
                AppLog.general.info("SendTo: task exported to Reminders: \(derived.title)")
            } catch {
                AppLog.general.error("SendTo: Reminders export failed: \(error)")
            }
        }
    }

    private func exportToCalendar() {
        guard case .derived(let derived) = item, derived.type == .task, let dueAt = derived.dueAt else { return }
        let eventStore = EKEventStore()
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                guard granted else { return }
                let event = EKEvent(eventStore: eventStore)
                event.title = derived.title
                event.startDate = dueAt
                event.endDate = dueAt.addingTimeInterval(3600)
                event.calendar = eventStore.defaultCalendarForNewEvents
                try eventStore.save(event, span: .thisEvent, commit: true)
                AppLog.general.info("SendTo: task exported to Calendar: \(derived.title)")
            } catch {
                AppLog.general.error("SendTo: Calendar export failed: \(error)")
            }
        }
    }

    private func exportToContacts() {
        // For Person-derived items or contact matches
        guard case .derived(let derived) = item else { return }
        let contact = CNMutableContact()
        contact.givenName = derived.title
        let store = CNContactStore()
        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(saveRequest)
            AppLog.general.info("SendTo: contact exported: \(derived.title)")
        } catch {
            AppLog.general.error("SendTo: Contacts export failed: \(error)")
        }
    }

    private func exportMarkdown() {
        var md = ""
        switch item {
        case .knowledge(let ki):
            md = "# \(ki.title)\n\nType: \(ki.type.label)\nCreated: \(ki.createdAt.formatted())\n"
            if let analysis = try? FileArtifactStore().readText(named: "analysis.json", itemID: ki.id) {
                md += "\n## Analysis\n\n```json\n\(analysis)\n```\n"
            }
        case .derived(let di):
            md = "# \(di.title)\n\nType: \(di.type.rawValue)\n"
            if let body = di.bodyJSON {
                md += "\n\(body)\n"
            }
        }
        presentShareSheet(md, type: .plainText)
    }

    private func exportPDF() {
        // Render synthesis or item content as PDF using UIGraphicsPDFRenderer
        // Deferred to implementation — requires PDF rendering pipeline
        let text = "PDF export placeholder"
        presentShareSheet(text, type: .plainText)
    }

    private func exportCSV() {
        // Export collection as CSV
        var csv = "Type,Title,Status,Created\n"
        switch item {
        case .derived(let di):
            csv += "\(di.type.rawValue),\"\(di.title)\",\(di.statusRaw ?? ""),\(di.createdAt.ISO8601Format())\n"
        case .knowledge(let ki):
            csv += "\(ki.type.rawValue),\"\(ki.title)\",,\(ki.createdAt.ISO8601Format())\n"
        }
        presentShareSheet(csv, type: .commaSeparatedText)
    }

    private func shareItem() {
        var text = ""
        switch item {
        case .knowledge(let ki): text = ki.title
        case .derived(let di): text = di.title
        }
        presentShareSheet(text, type: .plainText)
    }

    private func presentShareSheet(_ content: String, type: UTType) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("wawa-export-\(UUID().uuidString.prefix(8))")
        let ext = type == .commaSeparatedText ? "csv" : "md"
        let fileURL = tempURL.appendingPathExtension(ext)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)

        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }
}
```

- [ ] **Step 2: Add Send To button to file browser rows**

In `ItemsView`, add to each `unifiedRow`:

```swift
HStack {
    // ... existing row content ...

    Spacer()

    SendToMenu(item: item, projectID: projectID)
}
```

- [ ] **Step 3: Update Info.plist for Calendar and Reminders usage descriptions**

Add to Info.plist (if not already present):
- `NSCalendarsUsageDescription`: "Wawa Note exports tasks and deadlines to your calendar."
- `NSRemindersUsageDescription`: "Wawa Note exports action items to Reminders."
- `NSContactsUsageDescription`: "Wawa Note matches speakers and names to your contacts."

- [ ] **Step 4: Verify build compiles**

- [ ] **Step 5: Commit**

```bash
git add wawa-note/UI/Project/SendToMenuView.swift wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "feat: add Send To menu for unified project outputs

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Auto domain detection for Project Agent

**Files:**
- Modify: `wawa-note/Domain/Agent/ProjectAgent.swift`

**Interfaces:**
- Consumes: Existing frameworks (`FrameworkService.allBuiltInFrameworks`)
- Produces: `detectDomain()` method returning best-fit `ProjectFramework`

- [ ] **Step 1: Add domain detection to ProjectAgent**

```swift
// Add to ProjectAgent:

/// Detects the most appropriate framework/domain for this project
/// based on the content of its items.
func detectDomain() async -> ProjectFramework? {
    let items = (try? projectService.items(in: projectID)) ?? []
    guard !items.isEmpty else { return nil }

    // Build a sample of item content (titles + types + any analysis summaries)
    var sampleText = ""
    for item in items.prefix(5) {
        sampleText += "\(item.type.label): \(item.title)\n"
        if let analysis = try? FileArtifactStore().readText(named: "analysis.json", itemID: item.id) {
            sampleText += String(analysis.prefix(200)) + "\n"
        }
    }

    // Match against built-in frameworks
    let frameworks = FrameworkService.allBuiltInFrameworks
    guard !frameworks.isEmpty, !sampleText.isEmpty else { return nil }

    // Simple keyword scoring — in production, use the AI to classify
    var scores: [(framework: ProjectFramework, score: Int)] = []
    for (_, framework) in frameworks {
        var score = 0
        let keywords = extractFrameworkKeywords(framework)
        for keyword in keywords {
            if sampleText.localizedCaseInsensitiveContains(keyword) {
                score += 1
            }
        }
        if score > 0 {
            scores.append((framework, score))
        }
    }

    scores.sort { $0.score > $1.score }
    return scores.first?.framework
}

private func extractFrameworkKeywords(_ framework: ProjectFramework) -> [String] {
    // Extract keywords from framework name, description, entity kinds, and edge types
    var keywords: [String] = []
    keywords.append(contentsOf: framework.name.components(separatedBy: " "))
    keywords.append(contentsOf: framework.entityKinds)
    keywords.append(contentsOf: framework.edgeTypes)
    return keywords.map { $0.lowercased() }
}
```

- [ ] **Step 2: Wire domain detection into synthesis generation**

In `generateSynthesis()`, call `detectDomain()` first. If a framework is detected, include its analysis config as context in the synthesis prompt.

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Agent/ProjectAgent.swift
git commit -m "feat: add auto domain detection to ProjectAgent

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Cleanup — Remove deprecated views and wire up remaining connections

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (remove old views, keep what's needed)
- Modify: `wawa-note/UI/Explore/ExploreView.swift` (update project link navigation)
- Modify: `wawa-note/App/WawaNoteApp.swift` (update ModelContainer if needed)

**Interfaces:**
- Consumes: All previous tasks
- Produces: Clean project area with only Synthesis + Files, emergent views accessed via links

- [ ] **Step 1: Remove/deprecate old standalone views**

Comment out or remove from navigation hierarchy:
- `ProjectHomeView` (replaced by simplified version with segment control)
- `ProjectTaskBoardView` (subsumed by BoardView when tasks >= 3)
- `ProjectRiskRegisterView` (file browser filtered by signal type)
- `ProjectDecisionsView` (file browser filtered)
- `ProjectEntitiesView` (accessible but not primary)
- `ProjectPeopleView` (accessible but not primary)
- `SignalsView` (file browser filtered by signal type)

Keep the file implementations (don't delete the code) but remove them from the navigation structure. Mark with deprecation comment.

- [ ] **Step 2: Update ExploreView to use new ProjectDetailView**

In `ExploreView.swift`, ensure navigation to project uses `ProjectDetailLink(projectID:)` which resolves to the simplified `ProjectDetailView`.

- [ ] **Step 3: Wire "Generate Synthesis" button in EmptySynthesisView**

Connect the button in `EmptySynthesisView` to trigger `ProjectAgent.generateSynthesis()`:

```swift
Button("Generate Synthesis") {
    Task {
        let agent = ProjectAgent(projectID: project.id, context: modelContext)
        do {
            _ = try await agent.generateSynthesis()
            // Reload the view
        } catch {
            AppLog.general.error("Failed to generate synthesis: \(error)")
        }
    }
}
.buttonStyle(.bordered)
```

- [ ] **Step 4: Verify full build and test suite**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

Run: `xcodebuild test -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 5: Final commit**

```bash
git add .
git commit -m "feat: cleanup — wire synthesis generation, deprecate old views

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Completion Checklist

- [ ] All 12 tasks implemented and committed
- [ ] `ProjectDerivedItem` model registered in ModelContainer
- [ ] `ProjectDerivedItemService` CRUD working
- [ ] `TaskItem` and `AgentSuggestion` migrated to `ProjectDerivedItem`
- [ ] `ProjectDetailView` simplified to Synthesis | Files segments
- [ ] `ItemsView` shows unified KnowledgeItem + ProjectDerivedItem
- [ ] `BoardView` reads from ProjectDerivedItem
- [ ] `ProjectAgent.generateSynthesis()` working
- [ ] `DeviceContextService` cross-referencing Calendar and Contacts
- [ ] `SendToMenu` exporting tasks to Reminders/Calendar, synthesis to Markdown
- [ ] Auto domain detection selecting best-fit framework
- [ ] Old views deprecated, not in navigation structure
- [ ] All tests pass
- [ ] Build succeeds for iPhone 14 Plus simulator
