# Project Creation & Update — User Journeys Redesign

**Date:** 2026-06-21
**Status:** Approved
**Context:** Full redesign of the project lifecycle — creation and update — unifying fragmented APIs into a centralized service, redesigning creation UX with AI-assisted promotion and chat-based entry, and adding inline editing + proactive agent suggestions to Project Home.

## Problem Summary

Today, projects are created through 3+ disconnected paths (ProjectListView sheet, CreationSheetView inline, PromoteToProjectSheet hidden in item detail) and updated through 7+ scattered callers that mutate `Project` properties directly via SwiftData. There is no centralized validation, no consistent field-level provenance, no automatic snapshots, and no user-facing edit capabilities beyond archive/delete swipes and a "Generate Synthesis" button.

## Solution: Unified Service + Smart UX (Approach 1)

Three pillars:
1. **Unified ProjectService API** — single `create()` and `update()` entry points with field-level validation, provenance, and snapshotting
2. **Redesigned creation UX** — 2 entry points (CreateProjectSheet, Promote to Project), AI-assisted but user-decided, template-driven setup, chat-based creation always available
3. **Project Home with inline editing + Agent Suggestions** — collapsible info section with direct editing, proactive agent suggestion cards with 1-tap actions

## Section 1 — Unified Project Service API

### New contract

```swift
// MARK: Creation
func create(
    name: String,
    template: ProjectTemplate? = nil,    // pre-configures framework + views
    sourceItemIDs: [UUID] = [],          // items to link into the new project
    origin: FieldOrigin                  // .user | .agent | .system
) throws -> Project

// MARK: Update
func update(
    id: UUID,
    fields: ProjectUpdateFields,         // batch of changes, all optional
    origin: FieldOrigin,
    reason: String? = nil                // for audit trail / snapshot metadata
) throws -> Project

// MARK: Delete
func delete(id: UUID) throws             // existing, unchanged
```

### ProjectUpdateFields

```swift
struct ProjectUpdateFields {
    var name: String?
    var summary: String?
    var intention: String?
    var customInstructions: String?
    var colorHex: String?
    var iconName: String?
    var status: ProjectStatus?
    var frameworkId: String?
    var holdIngestionForDoubts: Bool?
    // NOT directly settable (system-only): healthScore, healthStatus, lastActivityAt
}
```

### What `update()` does internally

1. **Validation** — `FieldAuthorityService.canModify(field:origin:)` for each non-nil field
2. **Apply** — only authorized fields are written to the model
3. **Provenance** — `provenance.mark(field:origin:)` on every changed field
4. **Snapshot** — if any changes occurred, `VersioningService.createSnapshot()`
5. **Save** — single atomic `context.save()`

### Caller migration map

| Caller | New path |
|---|---|
| `ProjectListView` new-project sheet → `CreateProjectSheet` | `projectService.create(name:template:sourceItemIDs:origin:.user)` |
| `CreationSheetView` (project creation removed) | No longer creates projects — only captures items |
| `PromoteToProjectSheet` evolved | `projectService.create(name:template:sourceItemIDs:origin:.user)` with AI-suggested defaults |
| Chat agent `touch /projects/` | `projectService.create(name:template:nil, sourceItemIDs:[], origin:.agent)` |
| `ProjectListView` swipe-to-archive | `projectService.update(id:fields:{status:.archived}, origin:.user)` |
| `ShellInterpreter.echo` to project | `projectService.update(id:fields:jsonToFields(json), origin:.agent)` |
| `VFSService.updateProjectFromJSON` | `projectService.update(id:fields:jsonToFields(json), origin:.agent)` |
| `LensCatalogService.applyLens` | `projectService.update(id:fields:{frameworkId, frameworkJSON, customInstructions}, origin:.system)` |
| `FrameworkService.apply/restoreDefaults` | `projectService.update(id:fields:{frameworkId, frameworkJSON}, origin:.system)` |
| `ProjectIngestionPipeline.applyResults` (summary append) | `projectService.update(id:fields:{summary:newSummary}, origin:.agent)` |
| `ProjectHealthEngine` | Unchanged — writes `healthScore`/`healthStatus`/`lastActivityAt` directly (system-only fields) |
| `ConfigProjectService` | Unchanged — special hidden config project, keeps own path |

## Section 2 — Creation UX

### Two entry points, one consistent flow

#### Entry 1: `CreateProjectSheet` (from "+" button in ProjectListView)

```
┌──────────────────────────────────────┐
│  New Project                    Done │
│                                      │
│  📛 Name                             │
│  ┌──────────────────────────────────┐│
│  │ Launch Plan v2                  ││
│  └──────────────────────────────────┘│
│                                      │
│  📋 Starting from (optional)         │
│  ┌──────────────────────────────────┐│
│  │ + Add items to seed project     ││ ← multi-select of recent inbox items
│  └──────────────────────────────────┘│   or unassigned items
│                                      │
│  🧩 Template (optional)              │
│  ┌──────────────────────────────────┐│
│  │ ○ None                          ││
│  │ ● Meeting  → framework + views ││ ← radio list with descriptions
│  │ ○ Research                       ││
│  │ ○ Product                        ││
│  │ ○ Personal                       ││
│  └──────────────────────────────────┘│
│                                      │
│  🤖 Or: ask AI to set up            │ ← button that opens chat
│     "Organize my product launch"    │   with pre-filled prompt
└──────────────────────────────────────┘
```

#### Entry 2: "Promote to Project" (evolved from PromoteToProjectSheet)

Available from:
- **Item detail** → "Promote to Project" button (existing, was hidden — now prominent)
- **Inbox multi-select** → "Promote to Project" on selected items (new)
- **Proactive suggestion** → when system detects N related unassigned items (new)

Flow:
1. User selects items → "Promote to Project"
2. AI suggests name, template, and which related items to include (based on semantic similarity, shared people, temporal proximity)
3. User reviews AI suggestions (can edit name, add/remove items, switch template)
4. User confirms → `ProjectService.create(name:template:sourceItemIDs:origin:.user)`
5. Source items are linked to the new project
6. If template was chosen, framework is applied automatically

#### Chat-based creation (always available)

User can ask in chat: "create a project to organize the app launch." The agent:
1. Uses `ask_user` to confirm name + suggested template
2. Calls `projectService.create(name:template:sourceItemIDs:origin:.agent)`
3. Announces the created project with a navigable link

#### What disappears

- **CreationSheetView** no longer creates projects inline — capture only. Projects are created later via promote or dedicated "+"
- **Duplication** between ProjectListView and CreationSheetView is eliminated

## Section 3 — Update UX: Inline Editing + Agent Suggestions

### Project Home redesign

```
┌──────────────────────────────────────────┐
│ ← Explore    📁 Launch Plan v2    [ ··· ]│ ← toolbar: back, title inline editable, meatball
├──────────────────────────────────────────┤
│                                          │
│  ┌──────────────────────────────────┐    │
│  │ 🧠 Agent Suggestion             │    │ ← expandable card, at top
│  │ "3 new decisions this week.     │    │
│  │  Update summary?"               │    │
│  │              [Update] [Dismiss] │    │
│  └──────────────────────────────────┘    │
│                                          │
│  [Síntese]  [Arquivos]                   │ ← segment picker (already exists)
│                                          │
│  ── Project Info (collapsible) ──        │ ← NEW section
│  📛 Name                                 │
│  ┌──────────────────────────────────┐    │
│  │ Launch Plan v2              ✏️  │    │ ← tap to edit inline
│  └──────────────────────────────────┘    │
│                                          │
│  📝 Summary                             │
│  ┌──────────────────────────────────┐    │
│  │ Updated summary text here... ✏️ │    │ ← tap opens multi-line editor
│  └──────────────────────────────────┘    │
│                                          │
│  🎯 Intention                           │
│  ┌──────────────────────────────────┐    │
│  │ Coordinate launch activities  ✏️│    │
│  └──────────────────────────────────┘    │
│                                          │
│  🧩 Framework: Meeting                  │ ← tap opens framework picker
│                                          │
│  🎨 Color: ●●●○○  Icon: 📁             │ ← tap opens color/icon picker
│                                          │
│  ── Content ──                           │
│  [Synthesis tab content...]              │
└──────────────────────────────────────────┘
```

### Inline editing behavior

| Field | Action | Editor type |
|---|---|---|
| Name | Tap text | `TextField` inline, saves on blur |
| Summary | Tap text | Sheet with `TextEditor` multi-line |
| Intention | Tap text | Sheet with `TextEditor` + placeholder hint |
| Icon | Tap icon | Grid picker of SF Symbols (4 columns) |
| Color | Tap circle | Grid picker of 12 predefined colors |
| Framework | Tap chip | Sheet with framework list + schema preview |

Each save calls `ProjectService.update(id:fields:origin:.user)`.

### Agent Suggestions system

New model:

```swift
@Model
final class ProjectSuggestion {
    var id: UUID
    var projectID: UUID
    var title: String              // "3 new decisions detected"
    var body: String               // "Would you like to update the project summary?"
    var suggestionType: SuggestionType  // .summaryUpdate, .taskCreate, .riskAlert, .connectionProposal
    var proposedFields: ProjectUpdateFields?  // what would change if accepted
    var status: SuggestionStatus    // .pending, .accepted, .dismissed
    var createdAt: Date
}
```

**Who emits:** `ProjectAgent` after each pipeline run + periodically when project is opened.

**Where:** Cards at top of Project Home (before content), max 1-2 visible at a time.

**Actions by type:**

| Type | "Accept" action |
|---|---|
| `.summaryUpdate` | `projectService.update(id:fields:{summary:proposed}, origin:.agent)` |
| `.taskCreate` | Opens `TaskEditorView` pre-filled with suggested task data |
| `.riskAlert` | Opens graph/kanban with the risk item highlighted |
| `.connectionProposal` | Creates the suggested edge + shows confirmation |

**Lifecycle:** `pending → accepted/dismissed`. Suggestions expire after 7 days if ignored.

## Section 4 — Migration Plan

Strategy: **Progressive Strangulation.** New API coexists with existing callers. Each caller migrated one by one with regression test.

### Phase 1: New API + Simple Callers

Create `ProjectService.create()` and `ProjectService.update()` as new methods. Migrate simplest callers first.

| Caller | Complexity |
|---|---|
| `FrameworkService.apply()` / `restoreDefaults()` | Trivial |
| `LensCatalogService.applyLens()` | Trivial |
| `ProjectService.setColor()` | Trivial (already in service) |
| `ProjectListView` status toggle (swipe-to-archive) | Trivial |
| `ProjectListView` swipe-to-delete | Trivial |

### Phase 2: Creation Callers + New UI

| Caller | Complexity |
|---|---|
| `ProjectListView` "New Project" → new `CreateProjectSheet` | Medium (new UI + template picker) |
| `CreationSheetView` → remove project creation, capture-only | Medium (simplification, not new code) |
| `PromoteToProjectSheet` → evolve to AI-assisted flow | High (new UI + AI integration) |

### Phase 3: Complex Update Callers + Agent Suggestions

| Caller | Complexity |
|---|---|
| `VFSService.updateProjectFromJSON()` → map JSON to `ProjectUpdateFields` | Medium |
| `ShellInterpreter.echo` for projects → use `update()` | Medium |
| `ProjectIngestionPipeline.applyResults()` → use `update()` for summary append | High |
| New: `ProjectSuggestion` model + emission in `ProjectAgent` | High (new model + integration) |

### Phase 4: Inline Editing UI

| Component | Complexity |
|---|---|
| Collapsible "Project Info" section in `ProjectHomeView` | Medium |
| Inline name editor | Trivial |
| Summary/Intention sheet editors | Low |
| Icon picker (SF Symbols grid) | Medium |
| Color picker (12 predefined colors) | Low |
| Framework picker (list + schema preview) | Medium |
| Display + interact with `ProjectSuggestion` cards | Medium |

### What is NOT migrated

- **`ProjectHealthEngine`** — continues writing `healthScore`/`healthStatus`/`lastActivityAt` directly (system-only fields, no user authorization needed)
- **`ConfigProjectService`** — special hidden config project, keeps its own path
- **`VersioningService`** — unchanged, but now triggered from `ProjectService.update()` instead of scattered callers

## Section 5 — Design Decisions

1. **User decides, agent suggests** — the agent never creates or mutates a project without user confirmation. The `ProjectSuggestion` model enforces this: the agent emits `.pending` suggestions, the user accepts or dismisses. In chat, `ask_user` gates every mutation.
2. **Unified service, not event sourcing** — `ProjectService.update()` batches field changes atomically with snapshotting, avoiding the complexity of full event sourcing while still providing audit trail.
3. **Inline editing over settings screen** — fields are edited where they are seen (Project Home), not in a separate settings form. This reduces navigation and keeps context visible.
4. **Templates are lightweight** — a `ProjectTemplate` is just a preset `ProjectFramework` + optional initial tasks/views. No heavy CMS, no user-editable templates in v1. The template list shown (Meeting, Research, Product, Personal) is illustrative — the actual list maps to the 8 built-in frameworks already defined in `FrameworkService`: meeting, research, brainstorm, journal, coaching, legal, product, blank.
5. **Progressive migration** — the new `create()`/`update()` API ships alongside existing direct mutations. Each caller is migrated in a separate commit. At no point is the codebase in a broken intermediate state.
6. **Health fields bypass `update()`** — `healthScore`, `healthStatus`, and `lastActivityAt` are system-computed and never user-editable. They bypass `FieldAuthorityService` and continue to be written directly by `ProjectHealthEngine`.
