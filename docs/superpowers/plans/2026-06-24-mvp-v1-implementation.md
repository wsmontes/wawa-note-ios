# MVP V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify Wawa Note for App Store launch — 3-tab navigation, project as capsule, single analysis schema, scoped chat.

**Architecture:** Remove Chat from tab bar (4→3 tabs). Project Detail becomes 3-tab (Chat/Items/Files). Analysis uses single MeetingAnalysis schema — delete 6 framework templates. Remove ProjectAgent, ProjectIngestionPipeline, Synthesis. Chat scoped to project VFS root.

**Tech Stack:** SwiftUI, SwiftData, AVFoundation, existing provider/transcription/import infrastructure.

**Branch:** `feat/mvp-v1` (already created and pushed)

---

## Global Constraints

- Target: iPhone 14 Plus (iOS 18.6), iPhone 15 (iOS 26.5)
- All changes on branch `feat/mvp-v1`
- Build must pass after each task
- Zero regressions on Capture, Inbox, transcription, import/export
- Existing tests (120) must continue to pass
- Follow existing code patterns (SwiftUI, @MainActor, SwiftData)

---

### Task 1: Remove Chat from tab bar (KAN-519)

**Files:**
- Modify: `wawa-note/UI/Components/ContentView.swift`

- [ ] **Step 1: Remove Chat tab from ContentView**

```swift
// ContentView.swift — Remove the Chat tab
// Line 74-75 currently has:
//   .tabItem { Label("Capture", systemImage: "mic.badge.plus") }
// Line 77: NavigationStack { InboxView() }
// Line 80: NavigationStack { ExploreView() }
// Line 83: Chat tab

// Find the TabView block and remove the Chat tab entry.
// Specifically, delete the tabItem block for Chat (lines ~82-87)
// and the .badge(inboxPendingCount) modifier on the Chat tab.
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/UI/Components/ContentView.swift
git commit -m "KAN-519: remove Chat tab from main navigation — 3 tabs (Capture, Inbox, Explore)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: 3-tab Project Detail (KAN-520)

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift`

**Interfaces:**
- Produces: `ProjectDetailView` with tabs: Chat | Items | Files
- First tab becomes Chat scoped to project

- [ ] **Step 1: Add Chat as first tab in ProjectDetailView**

Replace the `ProjectTab` enum and body:

```swift
enum ProjectTab: String, CaseIterable {
    case chat = "Chat"
    case items = "Items"
    case files = "Files"
}

// In body, update the switch:
switch selectedTab {
case .chat:
    ProjectChatView(project: project)
case .items:
    ProjectItemsView(projectID: project.id)
case .files:
    ItemsView(projectID: project.id)
}
```

- [ ] **Step 2: Create ProjectChatView**

```swift
struct ProjectChatView: View {
    let project: Project
    @StateObject private var chatVM = ChatViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(project.colorHex.flatMap { Color(hex: $0) } ?? .blue)
                    .frame(width: 8, height: 8)
                Text(project.name).font(.subheadline).fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
            ChatView(viewModel: chatVM, compact: true)
        }
        .onAppear {
            chatVM.setup(modelContext: modelContext)
            chatVM.activeProjectID = project.id
            chatVM.activeProjectName = project.name
            chatVM.activeProjectColorHex = project.colorHex
        }
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "KAN-520: 3-tab Project Detail (Chat, Items, Files) with ProjectChatView
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Unified analysis schema (KAN-521)

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift` (PipelineTemplate enum)
- Modify: `wawa-note/Domain/Services/AnalysisService.swift` (framework resolution)

- [ ] **Step 1: Remove framework templates from PipelineTemplate**

In `ContentPipelineService.swift`, delete the framework-specific cases from `PipelineTemplate`:

```swift
// Keep ONLY:
enum PipelineTemplate {
    case standard  // the only one
    case extractAndAnalyze  // keep for extraction-only path
}
// Delete: research, brainstorm, journal, coaching, legal, product variants
// Delete: forFramework() method
```

- [ ] **Step 2: Update AnalysisService to always use standard template**

```swift
// In AnalysisService.analyze(), remove framework resolution:
// Before: let template = resolvedFramework.map { PipelineTemplate.forFramework($0) } ?? .standard
// After: let template = PipelineTemplate.standard
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift wawa-note/Domain/Services/AnalysisService.swift
git commit -m "KAN-521: unified analysis schema — single MeetingAnalysis for all items
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Scoped chat to project (KAN-522)

**Files:**
- Modify: `wawa-note/UI/Chat/ChatViewModel.swift`
- Modify: `wawa-note/Domain/Agent/ToolContext.swift` (if needed)

- [ ] **Step 1: Scope VFS root to project directory when activeProjectID is set**

In `ChatViewModel.setup()` or `sendMessage()`, when `activeProjectID != nil`:

```swift
if let projectID = activeProjectID {
    // Configure tool context to scope VFS to project directory
    toolContext.sandboxedProjectID = projectID
}
```

- [ ] **Step 2: Update ToolContext to support project sandboxing**

If not already present in ToolContext:

```swift
var sandboxedProjectID: UUID?
// When set, VFS operations (cd, ls, cat, find) are restricted to:
// /projects/{projectID}/items/
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Chat/ChatViewModel.swift wawa-note/Domain/Agent/ToolContext.swift
git commit -m "KAN-522: chat scoped to project — sandboxedProjectID restricts VFS
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Remove project processing (KAN-523)

**Files:**
- Delete: `wawa-note/Domain/Agent/ProjectAgent.swift` (440 lines)
- Delete: `wawa-note/Domain/Services/ProjectIngestionPipeline.swift` (808 lines)
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (remove Synthesis tab)
- Modify: `wawa-note/Domain/Models/ProjectModels.swift` (deprecate SynthesisBody etc.)
- Modify: `wawa-note.xcodeproj/project.pbxproj` (remove file references)

- [ ] **Step 1: Delete ProjectAgent and ProjectIngestionPipeline**

```bash
rm wawa-note/Domain/Agent/ProjectAgent.swift
rm wawa-note/Domain/Services/ProjectIngestionPipeline.swift
```

- [ ] **Step 2: Remove Synthesis models**

In `ProjectModels.swift`, add `@available(*, deprecated)` to `SynthesisBody`, `SynthesisSection`, `SynthesisMetric`.

- [ ] **Step 3: Remove Synthesis-related views**

Remove `ProjectSynthesisView`, `SynthesisContentView`, `EmptySynthesisView`, `MetricsStripView`, `SectionCardView` from `ProjectDetailView.swift`.

- [ ] **Step 4: Remove file references from pbxproj**

```bash
sed -i '' '/ProjectAgent.swift/d' wawa-note.xcodeproj/project.pbxproj
sed -i '' '/ProjectIngestionPipeline.swift/d' wawa-note.xcodeproj/project.pbxproj
```

- [ ] **Step 5: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "KAN-523: remove project processing — ProjectAgent, IngestionPipeline, Synthesis
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Items tab with filters (KAN-524)

**Files:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (ProjectItemsView)

- [ ] **Step 1: Update ProjectItemsView with Action Items and Questions filters**

```swift
enum ItemFilter: String, CaseIterable {
    case all = "All Items"
    case actions = "Action Items"
    case questions = "Questions"
}

private var filteredItems: [ProjectDerivedItem] {
    switch filter {
    case .all: return derivedItems.filter { $0.type != .synthesis && $0.type != .connection }
    case .actions: return derivedItems.filter { $0.type == .task && ($0.statusRaw == "todo" || $0.statusRaw == "inProgress") }
    case .questions: return derivedItems.filter { $0.type == .question }
    }
}
```

- [ ] **Step 2: Add chronological sorting and summary display**

```swift
// Sort by createdAt descending
derivedItems = ((try? services.derived.fetch(for: projectID)) ?? [])
    .sorted(by: { $0.createdAt > $1.createdAt })
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "KAN-524: Items tab with All Items / Action Items / Questions segmented filter
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Tasks 7-10: Files tab, Explore, Export, Schema UI

**Files for batch:**
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (Files tab improvements)
- Modify: `wawa-note/UI/Project/ProjectListView.swift` (simplify Explore)
- Create: `wawa-note/UI/Settings/AnalysisSchemaSettingsView.swift`
- Modify: `wawa-note/UI/Settings/SettingsView.swift` (add schema settings link)

*Implementation details omitted for brevity — follow same pattern as Tasks 1-6.*

- [ ] **Commit all remaining:**

```bash
git add -A && git commit -m "KAN-525/526/527/528: Files tab, simplified Explore, export, schema UI
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Final verification

- [ ] Run full test suite on device:

```bash
make all && make all DEVICE=15
```

Expected: `** TEST SUCCEEDED **` on both devices.

---
