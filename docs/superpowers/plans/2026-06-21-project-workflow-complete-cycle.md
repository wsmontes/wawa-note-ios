# Complete Project Workflow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the project workflow cycle: analysis outputs become visible entities (decisions, risks, questions → cards/tasks/signals), ingestion runs independently of analysis and triggers on project assignment, "Generate Synthesis" becomes "Update Project" with proper UX feedback, exports cover all derived outputs.

**Architecture:** Two architectural fixes unlock everything. (1) `AnalysisOutputParser` reads the existing `analysis.json` and creates `ProjectDerivedItem` records without a second AI call — decisions become derived items of a new type `.decision`, risks become signals, questions become derived items of type `.question`. (2) `ProjectIngestionPipeline.ingest()` is split so ingestion can be called independently when an item is assigned to a project (the current "add item → nothing happens" bug). The "Update Project" button runs a lightweight synthesis that reads all project items' analyses rather than re-calling the LLM per item.

**Tech Stack:** Swift 6, SwiftData, existing `ProjectDerivedItem` model (extended with 2 new types), existing `ProjectSuggestionService`, existing `ProjectAgent`.

## Global Constraints

- Target: iPhone 14 Plus (iOS 18.6.2), iPhone 15 (iOS 26.5), simulator (iOS 26.5)
- No new AI calls for ingestion — parse existing `analysis.json` directly
- `ProjectDerivedItem` is the unified model for all derived outputs (tasks, signals, synthesis, connections, decisions, questions)
- New `ProjectDerivedType` cases must be added to the enum in `ProjectModels.swift`
- All new files must be added to `project.pbxproj`
- `ProjectService.update()` is the single mutation path for project fields (from previous work)
- Follow existing patterns: `@MainActor` services, `@Model` for persistence, `ProjectSuggestionService` for proactive suggestions

---

## Phase 1: Analysis Output Parser + New Derived Types (3 tasks)

### Task 1: Add .decision and .question to ProjectDerivedType

**Files:**
- Modify: `wawa-note/Domain/Models/ProjectModels.swift` — add 2 enum cases

- [ ] **Step 1: Add enum cases**

Find `enum ProjectDerivedType` (~line 816) and add two cases:

```swift
enum ProjectDerivedType: String, Codable, Sendable, CaseIterable {
    case synthesis
    case task
    case signal
    case connection
    case decision     // NEW
    case question     // NEW
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Models/ProjectModels.swift
git commit -m "feat: add .decision and .question to ProjectDerivedType

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: AnalysisOutputParser

**Files:**
- Create: `wawa-note/Domain/Services/AnalysisOutputParser.swift`

**Interfaces:**
- Consumes: `KnowledgeItem` (for `analysis.json` path and `id`), `FileArtifactStore`
- Produces: `AnalysisOutput` struct with parsed arrays, `AnalysisOutputParser.parse(item:) throws -> AnalysisOutput`

- [ ] **Step 1: Create AnalysisOutputParser.swift**

```swift
import Foundation

// MARK: - AnalysisOutput

struct AnalysisOutput {
    let summary: String?
    let decisions: [DecisionItem]
    let actionItems: [ActionItem]
    let risks: [RiskItem]
    let openQuestions: [String]
    let peopleMentioned: [String]
    let topicsDiscussed: [String]
    let keyPoints: [String]

    struct DecisionItem: Codable {
        let decision: String
        let context: String?
        let owner: String?
    }

    struct ActionItem: Codable {
        let task: String
        let owner: String?
        let deadline: String?
    }

    struct RiskItem: Codable {
        let risk: String
        let mitigation: String?
    }

    var hasActionableContent: Bool {
        !decisions.isEmpty || !actionItems.isEmpty || !risks.isEmpty || !openQuestions.isEmpty
    }
}

// MARK: - AnalysisOutputParser

struct AnalysisOutputParser {
    /// Parse analysis.json for a given item.
    /// Returns nil if no analysis file exists or parsing fails.
    static func parse(item: KnowledgeItem, fileStore: FileArtifactStore) -> AnalysisOutput? {
        let analysisURL = fileStore.urlForAnalysis(of: item.id)
        guard let data = try? Data(contentsOf: analysisURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return AnalysisOutput(
            summary: json["summary"] as? String,
            decisions: parseDecisions(from: json),
            actionItems: parseActionItems(from: json),
            risks: parseRisks(from: json),
            openQuestions: json["open_questions"] as? [String] ?? [],
            peopleMentioned: json["people_mentioned"] as? [String] ?? [],
            topicsDiscussed: json["topics_discussed"] as? [String] ?? [],
            keyPoints: json["key_points"] as? [String] ?? []
        )
    }

    private static func parseDecisions(from json: [String: Any]) -> [AnalysisOutput.DecisionItem] {
        guard let items = json["decisions"] as? [[String: Any]] else { return [] }
        return items.compactMap { dict in
            guard let decision = dict["decision"] as? String else { return nil }
            return AnalysisOutput.DecisionItem(
                decision: decision,
                context: dict["context"] as? String,
                owner: dict["owner"] as? String
            )
        }
    }

    private static func parseActionItems(from json: [String: Any]) -> [AnalysisOutput.ActionItem] {
        guard let items = json["action_items"] as? [[String: Any]] else { return [] }
        return items.compactMap { dict in
            guard let task = dict["task"] as? String else { return nil }
            return AnalysisOutput.ActionItem(
                task: task,
                owner: dict["owner"] as? String,
                deadline: dict["deadline"] as? String
            )
        }
    }

    private static func parseRisks(from json: [String: Any]) -> [AnalysisOutput.RiskItem] {
        guard let items = json["risks"] as? [[String: Any]] else { return [] }
        return items.compactMap { dict in
            guard let risk = dict["risk"] as? String else { return nil }
            return AnalysisOutput.RiskItem(
                risk: risk,
                mitigation: dict["mitigation"] as? String
            )
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/AnalysisOutputParser.swift wawa-note.xcodeproj/project.pbxproj
git commit -m "feat: add AnalysisOutputParser — reads analysis.json without LLM call

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: DerivationService — Convert Analysis Output to ProjectDerivedItems

**Files:**
- Create: `wawa-note/Domain/Services/DerivationService.swift`

**Interfaces:**
- Consumes: `AnalysisOutput` (Task 2), `ProjectDerivedItemService` (existing), `ProjectSuggestionService` (existing)
- Produces: `DerivationService.derive(from:projectID:)` — creates derived items from analysis output

- [ ] **Step 1: Create DerivationService.swift**

```swift
import Foundation
import SwiftData

@MainActor
final class DerivationService {
    private let context: ModelContext
    private let derivedService: ProjectDerivedItemService

    init(context: ModelContext, derivedService: ProjectDerivedItemService) {
        self.context = context
        self.derivedService = derivedService
    }

    /// Convert analysis output into ProjectDerivedItems.
    /// Returns counts of what was created for UI feedback.
    func derive(from output: AnalysisOutput, projectID: UUID, sourceItemID: UUID) -> DerivationResult {
        var result = DerivationResult()

        // Action items → Tasks (in Kanban)
        for action in output.actionItems {
            do {
                let body = TaskBody(
                    description: action.task,
                    sourceSegmentIDs: [],
                    aiGenerated: true,
                    suggestedByItemID: sourceItemID
                )
                let bodyData = try? JSONEncoder().encode(body)
                let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

                _ = try derivedService.createTask(
                    projectID: projectID,
                    title: action.task,
                    ownerName: action.owner,
                    dueAt: action.deadline.flatMap { ISO8601DateFormatter().date(from: $0) },
                    bodyJSON: bodyStr,
                    sourceItemID: sourceItemID
                )
                result.tasksCreated += 1
            } catch {
                AppLog.provider.error("Derivation: failed to create task '\(action.task)': \(error)")
            }
        }

        // Decisions → ProjectDerivedItem.decision
        for decision in output.decisions {
            let body = DecisionBody(
                decision: decision.decision,
                context: decision.context,
                owner: decision.owner,
                sourceItemID: sourceItemID,
                status: "pending"
            )
            let bodyData = try? JSONEncoder().encode(body)
            let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }
            let item = ProjectDerivedItem(
                projectID: projectID,
                sourceItemID: sourceItemID,
                type: .decision,
                title: decision.decision,
                bodyJSON: bodyStr
            )
            context.insert(item)
            result.decisionsCreated += 1
        }

        // Risks → ProjectDerivedItem.signal
        for risk in output.risks {
            let body = SignalBody(
                title: "Risk: \(risk.risk)",
                detail: risk.mitigation ?? "No mitigation specified",
                severity: "medium",
                sourceItemID: sourceItemID
            )
            let bodyData = try? JSONEncoder().encode(body)
            let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }

            _ = try? derivedService.createSignal(
                projectID: projectID,
                title: "Risk: \(risk.risk)",
                detail: risk.mitigation ?? "",
                severity: "medium",
                sourceItemID: sourceItemID,
                bodyJSON: bodyStr
            )
            result.risksCreated += 1
        }

        // Open questions → ProjectDerivedItem.question
        for question in output.openQuestions {
            let body = QuestionBody(
                question: question,
                sourceItemID: sourceItemID,
                status: "open"
            )
            let bodyData = try? JSONEncoder().encode(body)
            let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }
            let item = ProjectDerivedItem(
                projectID: projectID,
                sourceItemID: sourceItemID,
                type: .question,
                title: question,
                bodyJSON: bodyStr
            )
            context.insert(item)
            result.questionsCreated += 1
        }

        try? context.save()
        return result
    }
}

// MARK: - Supporting types

struct DerivationResult {
    var tasksCreated = 0
    var decisionsCreated = 0
    var risksCreated = 0
    var questionsCreated = 0
    var isEmpty: Bool { tasksCreated == 0 && decisionsCreated == 0 && risksCreated == 0 && questionsCreated == 0 }
}

struct DecisionBody: Codable {
    let decision: String
    let context: String?
    let owner: String?
    let sourceItemID: UUID
    let status: String
}

struct QuestionBody: Codable {
    let question: String
    let sourceItemID: UUID
    let status: String
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/DerivationService.swift wawa-note.xcodeproj/project.pbxproj
git commit -m "feat: add DerivationService — converts analysis output to derived items

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 2: Fix Ingestion Pipeline (2 tasks)

### Task 4: Decouple Ingestion from Analysis

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift` — add `ingestOnly` path
- Modify: `wawa-note/Domain/Services/ProjectIngestionPipeline.swift` — add `ingestFromAnalysis` method

**Interfaces:**
- Consumes: `AnalysisOutputParser` (Task 2), `DerivationService` (Task 3)
- Produces: `ContentPipelineService.ingestOnly(itemID:projectID:)` — runs ingestion without re-analysis

- [ ] **Step 1: Add ingestFromAnalysis to ProjectIngestionPipeline**

In `ProjectIngestionPipeline.swift`, add a new method after `ingest()`:

```swift
/// Run ingestion directly from the existing analysis.json — no LLM call.
/// This is the fast path for items that already have analysis results.
func ingestFromAnalysis(itemID: UUID, projectID: UUID, using modelContext: ModelContext) -> DerivationResult {
    let fileStore = FileArtifactStore()
    let svc = KnowledgeItemService(context: modelContext)

    guard let item = try? svc.fetchItem(id: itemID) else {
        AppLog.provider.warning("ProjectIngestion: item \(itemID) not found")
        return DerivationResult()
    }

    guard let output = AnalysisOutputParser.parse(item: item, fileStore: fileStore) else {
        AppLog.provider.warning("ProjectIngestion: no analysis.json for item \(itemID)")
        return DerivationResult()
    }

    let derivedSvc = ProjectDerivedItemService(context: modelContext)
    let derivation = DerivationService(context: modelContext, derivedService: derivedSvc)
    let result = derivation.derive(from: output, projectID: projectID, sourceItemID: itemID)

    AppLog.provider.info("ProjectIngestion: derived from analysis — \(result.tasksCreated)T \(result.decisionsCreated)D \(result.risksCreated)R \(result.questionsCreated)Q")

    // Still run the LLM-based ingestion for summary update + connections
    if output.hasActionableContent {
        let suggestionSvc = ProjectSuggestionService(context: modelContext)
        suggestionSvc.emit(
            projectID: projectID,
            title: "New insights from \"\(item.title)\"",
            body: "\(result.tasksCreated) tasks, \(result.decisionsCreated) decisions, \(result.risksCreated) risks, \(result.questionsCreated) questions were created.",
            type: .summaryUpdate
        )
    }

    return result
}
```

Note: need to add `import Foundation` + `KnowledgeItemService` access. The `FileArtifactStore` already exists in the file's context.

- [ ] **Step 2: Add ingestOnly to ContentPipelineService**

In `ContentPipelineService.swift`, add after `process()`:

```swift
/// Re-run ingestion for an item that already has analysis results.
/// Used when an item is moved to a project or when "Update Project" is triggered.
func ingestOnly(itemID: UUID, projectID: UUID, using modelContext: ModelContext) {
    Task { @MainActor in
        _ = await ingestionPipeline.ingestFromAnalysis(
            itemID: itemID,
            projectID: projectID,
            using: modelContext
        )
    }
}
```

- [ ] **Step 3: Call ingestOnly when item is added to a project**

In `ContentPipelineService.process()`, modify the "skip if already analyzed" guard (~line 206-212):

```swift
// BEFORE:
guard forceReanalysis || item.analysisProviderId == nil || !AutomationSettings.shared.autoAnalyze else {
    if let projectID = item.projectID {
        await ingestionPipeline.ingest(itemID: itemID, projectID: projectID, using: modelContext)
    }
    return
}

// AFTER:
guard forceReanalysis || item.analysisProviderId == nil || !AutomationSettings.shared.autoAnalyze else {
    if let projectID = item.projectID {
        // Run fast ingestion from existing analysis.json (no LLM call)
        _ = await ingestionPipeline.ingestFromAnalysis(itemID: itemID, projectID: projectID, using: modelContext)
        // Also run LLM-based ingestion for summary + connections
        await ingestionPipeline.ingest(itemID: itemID, projectID: projectID, using: modelContext)
    }
    return
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift \
        wawa-note/Domain/Services/ProjectIngestionPipeline.swift
git commit -m "feat: decouple ingestion from analysis — add ingestFromAnalysis fast path

- ingestFromAnalysis parses existing analysis.json directly (no LLM call)
- ingestOnly added to ContentPipelineService for item→project assignment
- When item already analyzed and added to project, runs fast ingestion first

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Wire ingestion on project assignment

**Files:**
- Modify: `wawa-note/Domain/Services/ProjectService.swift` — trigger ingestion on `addItem`
- Modify: `wawa-note/UI/Inbox/InboxView.swift` — trigger ingestion on "Move to Project"

**Interfaces:**
- Consumes: `ContentPipelineService.ingestOnly` (Task 4)
- Produces: Items moved to project trigger derivation automatically

- [ ] **Step 1: Trigger ingestion in ProjectService.addItem()**

Find `addItem(_:to:)` in `ProjectService.swift`. After setting `item.projectID = pid` and saving, post a notification that triggers ingestion:

```swift
func addItem(_ itemID: UUID, to projectID: UUID) throws {
    guard let item = try? fetchItem(id: itemID) else { return }
    item.projectID = projectID
    item.updatedAt = Date()
    try context.save()

    // Trigger ingestion for already-analyzed items
    if item.analysisProviderId != nil {
        NotificationCenter.default.post(
            name: .contentPipelineStageChanged,
            object: itemID.uuidString,
            userInfo: ["stage": PipelineStage.ingesting.rawValue, "projectID": projectID.uuidString]
        )
    }
}
```

- [ ] **Step 2: Listen for ingestion trigger in ContentPipelineService**

Add observer in `ContentPipelineService.init()`:

```swift
NotificationCenter.default.addObserver(
    forName: .contentPipelineStageChanged,
    object: nil,
    queue: .main
) { [weak self] notification in
    guard let self,
          let stage = notification.userInfo?["stage"] as? String,
          stage == PipelineStage.ingesting.rawValue,
          let itemIDStr = notification.object as? String,
          let itemID = UUID(uuidString: itemIDStr),
          let projectIDStr = notification.userInfo?["projectID"] as? String,
          let projectID = UUID(uuidString: projectIDStr) else { return }
    self.ingestOnly(itemID: itemID, projectID: projectID, using: ModelContext(self.modelContainer))
}
```

- [ ] **Step 3: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/ProjectService.swift \
        wawa-note/Domain/Services/ContentPipelineService.swift
git commit -m "feat: auto-trigger ingestion when item is moved to project

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 3: Decision & Question Cards in Dashboard (2 tasks)

### Task 6: DecisionCardView + QuestionCardView

**Files:**
- Create: `wawa-note/UI/Project/DecisionCardView.swift`
- Create: `wawa-note/UI/Project/QuestionCardView.swift`

- [ ] **Step 1: Create DecisionCardView.swift**

```swift
import SwiftUI

struct DecisionCardView: View {
    let decision: ProjectDerivedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hammer.fill").foregroundStyle(.orange)
                Text("Decision").font(.caption).foregroundStyle(.orange)
                Spacer()
                Text(statusLabel).font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text(decision.title).font(.subheadline).fontWeight(.medium)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statusLabel: String {
        // Parse status from bodyJSON — "pending", "confirmed", "rejected"
        guard let json = decision.bodyJSON,
              let data = json.data(using: .utf8),
              let body = try? JSONDecoder().decode([String: String].self, from: data),
              let status = body["status"] else { return "pending" }
        return status
    }

    private var statusColor: Color {
        switch statusLabel {
        case "confirmed": return .green
        case "rejected": return .red
        default: return .orange
        }
    }
}

struct QuestionCardView: View {
    let question: ProjectDerivedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
                Text("Open Question").font(.caption).foregroundStyle(.blue)
            }
            Text(question.title).font(.subheadline)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/DecisionCardView.swift \
        wawa-note/UI/Project/QuestionCardView.swift \
        wawa-note.xcodeproj/project.pbxproj
git commit -m "feat: add DecisionCardView + QuestionCardView

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Add Decisions + Questions sections to Project Dashboard

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` — add `decisionsSection` and `questionsSection`

- [ ] **Step 1: Add Queries and computed sections to ProjectHomeView**

Add these `@Query` properties:

```swift
@Query private var projectDecisions: [ProjectDerivedItem]
@Query private var projectQuestions: [ProjectDerivedItem]
```

Add to `init`:

```swift
let pid3 = project.id
let decisionRaw = ProjectDerivedType.decision.rawValue
_projectDecisions = Query(
    filter: #Predicate { $0.projectID == pid3 && $0.typeRaw == decisionRaw },
    sort: \ProjectDerivedItem.createdAt, order: .reverse
)
let pid4 = project.id
let questionRaw = ProjectDerivedType.question.rawValue
_projectQuestions = Query(
    filter: #Predicate { $0.projectID == pid4 && $0.typeRaw == questionRaw },
    sort: \ProjectDerivedItem.createdAt, order: .reverse
)
```

Add computed sections after PendingSection in the ScrollView:

```swift
// Decisions
if !projectDecisions.isEmpty {
    VStack(alignment: .leading, spacing: 8) {
        Text("Decisions").font(.headline)
        ForEach(projectDecisions.prefix(3)) { decision in
            DecisionCardView(decision: decision)
        }
    }
    .padding(.horizontal)
}

// Open Questions
if !projectQuestions.isEmpty {
    VStack(alignment: .leading, spacing: 8) {
        Text("Open Questions").font(.headline)
        ForEach(projectQuestions.prefix(3)) { question in
            QuestionCardView(question: question)
        }
    }
    .padding(.horizontal)
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "feat: add Decisions + Questions sections to project dashboard

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 4: Fix "Update Project" Button (2 tasks)

### Task 8: Robust Update Project with Loading + Error Feedback

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` — add `isUpdating` state + error handling
- Modify: `wawa-note/Domain/Agent/ProjectAgent.swift` — add provider validation

- [ ] **Step 1: Add provider validation to ProjectAgent**

At the top of `generateSynthesis()`:

```swift
// Validate provider availability before launching agent
guard let provider = try? ProviderRouter.resolveActive(context: context) else {
    AppLog.provider.error("ProjectAgent: no active provider configured")
    throw ProjectAgentError.noProvider
}

let model = AIConfigService.shared.resolvedModelFor(feature: "analysis", context: context) ?? ""
guard !model.isEmpty else {
    AppLog.provider.error("ProjectAgent: no model available for analysis")
    throw ProjectAgentError.noModel
}
```

Add error enum:

```swift
enum ProjectAgentError: LocalizedError {
    case noProvider
    case noModel
    var errorDescription: String? {
        switch self {
        case .noProvider: return "No AI provider configured. Add one in Settings."
        case .noModel: return "No analysis model available. Check your provider settings."
        }
    }
}
```

- [ ] **Step 2: Update the button in ProjectHomeView**

Replace the current synthesis button with:

```swift
// In the dashboard, replace "Generate Synthesis" button:
if project.synthesis == nil && !projectItems.isEmpty {
    VStack(spacing: 8) {
        Button {
            isUpdating = true
            updateError = nil
            Task {
                do {
                    let agent = ProjectAgent(projectID: project.id, context: modelContext)
                    _ = try await agent.generateSynthesis()
                } catch {
                    updateError = error.localizedDescription
                }
                isUpdating = false
            }
        } label: {
            HStack {
                if isUpdating {
                    ProgressView().scaleEffect(0.8)
                }
                Label(isUpdating ? "Updating..." : "Update Project", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isUpdating)

        if let error = updateError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }
    .padding(.horizontal)
}
```

Add state vars:

```swift
@State private var isUpdating = false
@State private var updateError: String?
```

- [ ] **Step 3: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift \
        wawa-note/Domain/Agent/ProjectAgent.swift
git commit -m "feat: robust Update Project button with loading + error states

- Provider validation in ProjectAgent before launching agent
- ProjectAgentError enum for user-facing error messages
- Button shows spinner while updating, error message on failure
- Renamed from Generate Synthesis to Update Project

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Add item-level "Create Tasks from Analysis" action

**Files:**
- Modify: `wawa-note/UI/Knowledge/KnowledgeDetailView.swift` — add action button

- [ ] **Step 1: Add action to KnowledgeDetailView toolbar**

Add a toolbar button visible when item has analysis AND is in a project:

```swift
// In KnowledgeDetailView toolbar, after existing buttons:
if item.analysisProviderId != nil, let pid = item.projectID {
    ToolbarItem(placement: .primaryAction) {
        Button {
            let pipeline = ContentPipelineService(
                ingestionPipeline: ingestionPipeline,
                ingestionState: ingestionState,
                modelContainer: modelContainer
            )
            pipeline.ingestOnly(itemID: item.id, projectID: pid, using: modelContext)
        } label: {
            Label("Derive Tasks", systemImage: "arrow.triangle.branch")
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Knowledge/KnowledgeDetailView.swift
git commit -m "feat: add Derive Tasks button to KnowledgeDetailView toolbar

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Final Build + Deploy + Full Test

**Files:**
- No changes — verification only

- [ ] **Step 1: Run all unit tests**

```bash
xcodebuild test -project wawa-note.xcodeproj -scheme "wawa-note" -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -10
```

- [ ] **Step 2: Deploy to both devices**

```bash
make deploy DEVICE=14 && make deploy DEVICE=15
```

- [ ] **Step 3: Push**

```bash
git push origin feat/project-creation-update-journeys
```

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "chore: final verification — full test suite + device deploy

Co-Authored-By: Claude <noreply@anthropic.com>"
```
