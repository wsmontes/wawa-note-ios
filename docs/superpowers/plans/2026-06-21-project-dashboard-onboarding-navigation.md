# Project Dashboard + Onboarding + Navigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the Explore tab into a focused project list, redesign Project Home as a living dashboard, and add intelligent onboarding that detects orphan Inbox items and suggests project creation.

**Architecture:** Three independent waves. Wave C (navigation simplification) comes first — it's the smallest, removes cruft, and clears the ground. Wave A (dashboard) is the core — replaces ProjectHomeView's 2-tab picker with a scrollable dashboard of section cards fed by existing services. Wave B (onboarding) adds a critical-mass detector and guided empty states. All data sources already exist — this is a UI composition project, not a backend project.

**Tech Stack:** SwiftUI, SwiftData, existing services (ProjectSuggestionService, ProjectTimelineView data, ProjectDerivedItem queries).

## Global Constraints

- Target: iPhone 14 Plus (iOS 18.6.2), iPhone 15 (iOS 26.5), simulator (iOS 26.5)
- All data sources already exist — no new services or models needed (except 1 enum case)
- Keep existing components intact even when removing them from Explore tab (FileBrowserView, TimelineExplorerView are used elsewhere)
- Follow existing SwiftUI patterns: `@Environment`, `@State`, `@MainActor`
- New files must be added to `project.pbxproj`
- Each wave produces independently shippable software

---

## Wave C — Navigation Simplification (1 task)

### Task 1: Remove Global Timeline + FileBrowser from Explore

**Files:**
- Modify: `wawa-note/UI/Components/ContentView.swift:190-231` — simplify ExploreView

**Interfaces:**
- Consumes: `ProjectListView` (existing)
- Produces: Simplified `ExploreView` — only project list, no segments

- [ ] **Step 1: Replace ExploreView body**

Replace the entire `ExploreView` struct (lines 190-231 in ContentView.swift):

```swift
struct ExploreView: View {
    @EnvironmentObject private var chatState: ChatOverlayState
    @EnvironmentObject private var chatViewModel: ChatViewModel

    var body: some View {
        ProjectListView()
            .onAppear {
                chatState.context = .exploreProjects
                chatViewModel.pregenerateGreeting(for: .exploreProjects)
            }
    }
}
```

Remove: `ExploreTab` enum, `@State private var selectedTab`, the `Picker`, the `switch` cases for `.files` and `.timeline`.

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Components/ContentView.swift
git commit -m "refactor: simplify Explore tab — remove global FileBrowser and Timeline

Explore now shows only the project list. FileBrowserView and TimelineExplorerView
remain available for project-internal use.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Wave A — Project Dashboard (4 tasks)

### Task 2: HeroStatsCard Component

**Files:**
- Create: `wawa-note/UI/Project/HeroStatsCard.swift`

**Interfaces:**
- Consumes: `Project` (existing model), item/task counts from SwiftData queries
- Produces: `HeroStatsCard` view — shows item count, task count, health, last activity

- [ ] **Step 1: Create HeroStatsCard.swift**

```swift
import SwiftUI
import SwiftData

struct HeroStatsCard: View {
    let project: Project
    let itemCount: Int
    let taskCount: Int
    let openTaskCount: Int

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                statItem(value: "\(itemCount)", label: "Items", icon: "doc.text", color: .blue)
                statItem(value: "\(taskCount)", label: "Tasks", icon: "checklist", color: .green)
                statItem(value: "\(openTaskCount)", label: "Open", icon: "circle", color: .orange)
            }

            Divider()

            HStack {
                if let lastActivity = project.lastActivityAt {
                    Label("Last activity: \(lastActivity.formatted(.relative(presentation: .numeric)))", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let score = project.healthScore {
                    Label("\(Int(score * 100))%", systemImage: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(healthColor(score))
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2).fontWeight(.bold)
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption2)
            }
            .foregroundStyle(color)
        }
    }

    private func healthColor(_ score: Double) -> Color {
        if score >= 0.8 { return .green }
        if score >= 0.5 { return .orange }
        return .red
    }
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/HeroStatsCard.swift wawa-note.xcodeproj/project.pbxproj
git commit -m "feat: add HeroStatsCard — item/task/health summary for project dashboard

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: RecentActivitySection Component

**Files:**
- Create: `wawa-note/UI/Project/RecentActivitySection.swift`

**Interfaces:**
- Consumes: KnowledgeItem + ProjectDerivedItem queries for recent events
- Produces: `RecentActivitySection` — last 5 events in the project

- [ ] **Step 1: Create RecentActivitySection.swift**

```swift
import SwiftUI
import SwiftData

struct RecentActivitySection: View {
    let projectID: UUID
    @Query private var recentItems: [KnowledgeItem]
    @Query private var recentDerived: [ProjectDerivedItem]

    init(projectID: UUID) {
        self.projectID = projectID
        let pid = projectID
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        _recentItems = Query(
            filter: #Predicate { $0.projectID == pid && $0.updatedAt > sevenDaysAgo },
            sort: \KnowledgeItem.updatedAt, order: .reverse
        )
        _recentDerived = Query(
            filter: #Predicate { $0.projectID == pid && $0.updatedAt > sevenDaysAgo },
            sort: \ProjectDerivedItem.updatedAt, order: .reverse
        )
    }

    var body: some View {
        let events = combinedEvents().prefix(5)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Activity").font(.headline)

                ForEach(Array(events), id: \.id) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.icon)
                            .font(.caption)
                            .foregroundStyle(event.color)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.subheadline)
                            Text(event.time.formatted(.relative(presentation: .numeric)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func combinedEvents() -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for item in recentItems.prefix(5) {
            events.append(ActivityEvent(
                id: item.id.uuidString,
                title: item.title,
                time: item.updatedAt,
                icon: item.type == .audio ? "recordingtape" : "doc.text",
                color: .blue
            ))
        }
        for derived in recentDerived.prefix(5) {
            let (icon, color): (String, Color) = {
                switch derived.derivedType {
                case .task: return derived.status == .done ? ("checkmark.circle", .green) : ("circle", .orange)
                case .signal: return ("exclamationmark.triangle", .yellow)
                case .synthesis: return ("sparkles", .purple)
                default: return ("doc.text", .gray)
                }
            }()
            events.append(ActivityEvent(
                id: derived.id.uuidString,
                title: derived.title,
                time: derived.updatedAt,
                icon: icon, color: color
            ))
        }
        return events.sorted(by: { $0.time > $1.time })
    }
}

private struct ActivityEvent {
    let id: String
    let title: String
    let time: Date
    let icon: String
    let color: Color
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/RecentActivitySection.swift wawa-note.xcodeproj/project.pbxproj
git commit -m "feat: add RecentActivitySection — last 5 project events

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: PendingSection Component

**Files:**
- Create: `wawa-note/UI/Project/PendingSection.swift`

**Interfaces:**
- Consumes: `ProjectDerivedItem` query for open tasks
- Produces: `PendingSection` — open tasks and pending decisions

- [ ] **Step 1: Create PendingSection.swift**

```swift
import SwiftUI
import SwiftData

struct PendingSection: View {
    let projectID: UUID

    @Query private var openTasks: [ProjectDerivedItem]

    init(projectID: UUID) {
        self.projectID = projectID
        let pid = projectID
        let todoRaw = ProjectDerivedStatus.todo.rawValue
        let inProgressRaw = ProjectDerivedStatus.inProgress.rawValue
        _openTasks = Query(
            filter: #Predicate {
                $0.projectID == pid &&
                $0.typeRaw == "task" &&
                ($0.statusRaw == todoRaw || $0.statusRaw == inProgressRaw)
            },
            sort: \ProjectDerivedItem.dueAt, order: .forward
        )
    }

    var body: some View {
        if !openTasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pending").font(.headline)

                ForEach(openTasks.prefix(5)) { task in
                    HStack(spacing: 8) {
                        Image(systemName: task.status == .inProgress ? "circle.dotted" : "circle")
                            .font(.caption)
                            .foregroundStyle(task.priority == .high || task.priority == .critical ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.subheadline)
                            if let owner = task.ownerName {
                                Text("@\(owner)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let due = task.dueAt {
                            Text(due.formatted(.relative(presentation: .numeric)))
                                .font(.caption2).foregroundStyle(due < Date() ? .red : .secondary)
                        }
                    }
                }

                if openTasks.count > 5 {
                    Text("+ \(openTasks.count - 5) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/PendingSection.swift wawa-note.xcodeproj/project.pbxproj
git commit -m "feat: add PendingSection — open tasks and deadlines for dashboard

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Redesign ProjectHomeView as Dashboard

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` — replace `ProjectHomeView` body with scrollable dashboard

**Interfaces:**
- Consumes: `HeroStatsCard` (Task 2), `RecentActivitySection` (Task 3), `PendingSection` (Task 4), `SuggestionCardView` (existing), `ProjectSuggestionService` (existing), `ItemsView` (existing), `ProjectSynthesisView` (existing)
- Produces: Redesigned `ProjectHomeView` with scrollable dashboard

- [ ] **Step 1: Replace ProjectHomeView body**

Replace the entire `ProjectHomeView` struct body (from line 116) with:

```swift
@State private var suggestionService: ProjectSuggestionService?
@State private var suggestions: [ProjectSuggestion] = []
@State private var infoExpanded = false
@State private var editingName = ""
@State private var editingSummary = ""
@State private var editingIntention = ""
@State private var showSummaryEditor = false
@State private var showIntentionEditor = false
@State private var showIconPicker = false
@State private var showColorPicker = false
@State private var showFrameworkPicker = false
@State private var showAllFiles = false

// Remove: enum ProjectTab, @State private var selectedTab

var body: some View {
    ScrollView {
        VStack(spacing: 16) {
            // Agent suggestions
            if !suggestions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        SuggestionCardView(suggestion: suggestion) { action in
                            handleSuggestion(suggestion, action: action)
                        }
                    }
                }
                .padding(.horizontal)
            }

            // Hero stats
            HeroStatsCard(
                project: project,
                itemCount: itemCount,
                taskCount: taskCount,
                openTaskCount: openTaskCount
            )
            .padding(.horizontal)

            // Recent activity
            RecentActivitySection(projectID: project.id)
                .padding(.horizontal)

            // Pending
            PendingSection(projectID: project.id)
                .padding(.horizontal)

            // Synthesis
            synthesisSection
                .padding(.horizontal)

            // Project Info (collapsible — reused from Task 8-10)
            DisclosureGroup("Project Info", isExpanded: $infoExpanded) {
                // ... same Project Info content from before (name, summary, intention, icon, color, framework) ...
            }
            .padding(.horizontal)

            // Files (condensed)
            filesSection
                .padding(.horizontal)

            Spacer().frame(height: 16)
        }
        .padding(.top, 8)
    }
    .navigationTitle(project.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showCaptureSheet = true } label: { Label("Add Item", systemImage: "plus") }
                Button { exportMarkdown() } label: { Label("Export Markdown", systemImage: "doc.richtext") }
                Button { exportJSON() } label: { Label("Export JSON", systemImage: "doc.text") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
    .sheet(isPresented: $showAllFiles) {
        NavigationStack {
            ItemsView(projectID: project.id)
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showAllFiles = false } }
                }
        }
    }
    // ... keep existing sheets for summary/intention/icon/color/framework pickers ...
    .onAppear {
        chatState.context = .project(project.id)
        editingName = project.name
        editingSummary = project.summary ?? ""
        editingIntention = project.intention ?? ""
        suggestionService = ProjectSuggestionService(context: modelContext)
        suggestions = suggestionService?.pending(for: project.id) ?? []
    }
}
```

Add these computed properties and views inside `ProjectHomeView`:

```swift
// Item/task counts for HeroStatsCard
@Query private var projectItems: [KnowledgeItem]
@Query private var projectTasks: [ProjectDerivedItem]

private var itemCount: Int { projectItems.count }
private var taskCount: Int { projectTasks.filter { $0.typeRaw == "task" }.count }
private var openTaskCount: Int {
    projectTasks.filter { $0.typeRaw == "task" && ($0.statusRaw == "todo" || $0.statusRaw == "inProgress") }.count
}

private var synthesisSection: some View {
    if let _ = project.synthesis {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Synthesis").font(.headline)
                Spacer()
                if let updated = project.synthesisUpdatedAt {
                    Text(updated.formatted(.relative(presentation: .numeric)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProjectSynthesisView(project: project)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            NavigationLink("Read full synthesis") {
                ProjectSynthesisView(project: project)
            }
            .font(.caption)
        }
    } else if !projectItems.isEmpty {
        Button {
            Task { await generateSynthesis() }
        } label: {
            Label("Generate Synthesis", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

private var filesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Text("Files").font(.headline)
            Spacer()
            Text("\(itemCount) items").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(projectItems.prefix(5)) { item in
            HStack {
                Image(systemName: item.type == .audio ? "recordingtape" : "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(item.title).font(.subheadline).lineLimit(1)
                    Text(item.type.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        if itemCount > 5 {
            Button("View all \(itemCount) files") { showAllFiles = true }
                .font(.caption)
        }
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 16))
}
```

Add `init` with Queries:

```swift
init(project: Project) {
    self.project = project
    let pid = project.id
    _projectItems = Query(
        filter: #Predicate { $0.projectID == pid },
        sort: \KnowledgeItem.updatedAt, order: .reverse
    )
    let pid2 = project.id
    _projectTasks = Query(
        filter: #Predicate { $0.projectID == pid2 },
        sort: \ProjectDerivedItem.updatedAt, order: .reverse
    )
}
```

Remove: `ProjectTab` enum, `selectedTab` state, the segmented `Picker`, the `switch selectedTab` block.

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "feat: redesign ProjectHomeView as scrollable dashboard

Replace Synthesis|Files picker with scrollable dashboard:
HeroStatsCard → RecentActivity → Pending → Synthesis → Info → Files.
Files open as sheet with full list. Synthesis shows inline preview.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Wave B — Intelligent Onboarding (3 tasks)

### Task 6: Add .projectCreation to SuggestionType

**Files:**
- Modify: `wawa-note/Domain/Models/ProjectSuggestion.swift` — add enum case

- [ ] **Step 1: Add enum case**

```swift
enum SuggestionType: String, Codable, CaseIterable, Sendable {
    case summaryUpdate
    case taskCreate
    case riskAlert
    case connectionProposal
    case projectCreation  // NEW
}
```

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Models/ProjectSuggestion.swift
git commit -m "feat: add .projectCreation suggestion type

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: InboxCriticalMassDetector

**Files:**
- Create: `wawa-note/Domain/Services/InboxCriticalMassDetector.swift`

**Interfaces:**
- Consumes: `KnowledgeItem` query (items without projectID), `ProjectSuggestionService` (existing)
- Produces: `InboxCriticalMassDetector` — checks for orphan items, emits `ProjectSuggestion` if threshold met

- [ ] **Step 1: Create InboxCriticalMassDetector.swift**

```swift
import Foundation
import SwiftData

@MainActor
final class InboxCriticalMassDetector {
    private let context: ModelContext
    private let threshold = 3

    init(context: ModelContext) {
        self.context = context
    }

    /// Check if there are enough orphan items to suggest project creation.
    /// Returns true if a suggestion was emitted.
    func checkAndSuggest() -> Bool {
        let orphanItems = fetchOrphanItems()
        guard orphanItems.count >= threshold else { return false }

        let titles = orphanItems.prefix(5).map { "• \($0.title)" }.joined(separator: "\n")
        let suggestionSvc = ProjectSuggestionService(context: context)

        // Check if suggestion already exists (dedup)
        let existing = suggestionSvc.pending(for: orphanItems.first?.id ?? UUID(), limit: 10)
        if existing.contains(where: { $0.suggestionType == .projectCreation }) { return false }

        suggestionSvc.emit(
            projectID: orphanItems.first?.id ?? UUID(), // Use first item's ID as anchor; UI resolves to inbox context
            title: "You have \(orphanItems.count) unassigned items",
            body: "These look related. Create a project to organize them?\n\n\(titles)",
            type: .projectCreation
        )
        return true
    }

    private func fetchOrphanItems() -> [KnowledgeItem] {
        let descriptor = FetchDescriptor<KnowledgeItem>(
            predicate: #Predicate { $0.projectID == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/InboxCriticalMassDetector.swift wawa-note.xcodeproj/project.pbxproj
git commit -m "feat: add InboxCriticalMassDetector — triggers projectCreation suggestion at ≥3 orphans

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Onboarding Card in ProjectListView + Guided Empty States

**Files:**
- Modify: `wawa-note/UI/Project/ProjectListView.swift` — add onboarding card and guided empty state

**Interfaces:**
- Consumes: `InboxCriticalMassDetector` (Task 7), `ProjectSuggestionService` (existing)
- Produces: Onboarding experience in project list

- [ ] **Step 1: Add onboarding card and empty state to ProjectListView**

Add to `ProjectListView` state:

```swift
@State private var onboardingSuggestion: ProjectSuggestion?
@State private var showPromoteSheet = false
@State private var orphanItems: [KnowledgeItem] = []
```

Add an onboarding section at the top of the list:

```swift
// At the top of the List, before ForEach(projects):
if let suggestion = onboardingSuggestion {
    Section {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                Text(suggestion.title).font(.subheadline).fontWeight(.semibold)
            }
            Text(suggestion.body).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Dismiss") {
                    try? ProjectSuggestionService(context: modelContext).dismiss(suggestion)
                    onboardingSuggestion = nil
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button("Create Project") {
                    showPromoteSheet = true
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }
}
```

Update the empty state (replace the current one):

```swift
if projects.isEmpty {
    VStack(spacing: 24) {
        Spacer().frame(height: 60)

        Image(systemName: "folder.badge.questionmark")
            .font(.system(size: 48))
            .foregroundStyle(.secondary)

        Text("Welcome to Wawa Note")
            .font(.title2).fontWeight(.semibold)

        Text("Capture meetings, notes, or documents.\nThey become living projects with tasks, decisions, and connections.")
            .font(.subheadline).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

        VStack(spacing: 12) {
            Button {
                // Trigger recording
            } label: {
                Label("Record your first meeting", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showNewProject = true
            } label: {
                Label("Create a project", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 32)
    }
    .listRowBackground(Color.clear)
}
```

Add `onAppear` to trigger the detector:

```swift
.onAppear {
    let detector = InboxCriticalMassDetector(context: modelContext)
    if detector.checkAndSuggest() {
        let svc = ProjectSuggestionService(context: modelContext)
        // Find the projectCreation suggestion just emitted
        // (InboxCriticalMassDetector emits it; we fetch it back)
        let allSuggestions = (try? context.fetch(FetchDescriptor<ProjectSuggestion>())) ?? []
        onboardingSuggestion = allSuggestions.first { $0.suggestionType == .projectCreation && $0.status == .pending }
    }
}
```

- [ ] **Step 2: Build and verify**

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Project/ProjectListView.swift
git commit -m "feat: add onboarding card + guided empty state to ProjectListView

- Shows projectCreation suggestion card when ≥3 orphan items in Inbox
- Guided empty state with Record / Create Project buttons
- Dismiss persists via ProjectSuggestionService

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Final Build + Deploy

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

- [ ] **Step 3: Commit**

```bash
git commit --allow-empty -m "chore: final verification — tests pass, devices updated

Co-Authored-By: Claude <noreply@anthropic.com>"
```
