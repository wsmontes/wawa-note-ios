# Project Dashboard + Onboarding + Navigation Simplification — Design Spec

**Date:** 2026-06-21
**Status:** Approved
**Context:** The product has evolved significantly from meeting recorder to knowledge workspace, but the UI doesn't reflect this. The Explore tab shows projects as a file browser, not as living entities. The first-run experience doesn't guide users toward the core value prop (project memory). The navigation has accumulated cruft (global timeline, file browser in Explore) that dilutes focus.

## Problem Summary

Three gaps between architecture and experience:

1. **Project Home is a file browser, not a dashboard.** The user sees "Síntese | Arquivos" tabs. They don't see what changed, what needs attention, or the intelligence the system has derived. The agent's work is invisible.

2. **No guided path from capture to project.** A user records a meeting → it lands in Inbox → then what? Promote to Project is hidden. There's no suggestion, no nudge, no "next step."

3. **Navigation bloat.** The Explore tab has 3 segments (Projects, Files, Timeline). Files duplicates Inbox. Timeline is noise at global scope. The tab structure doesn't reflect the product's value prop.

## Solution: Three Waves

### Wave A: Project Home as Living Dashboard

Redesign `ProjectHomeView` from a 2-tab segmented control to a scrollable dashboard with sections that reveal project intelligence.

### Wave B: Intelligent Onboarding

Detect "critical mass" in Inbox and proactively suggest project creation. Guide the first-run experience toward the core loop: capture → promote → explore.

### Wave C: Navigation Simplification

Remove global Timeline and FileBrowser from Explore. Reduce to Projects-only. Make the chat overlay contextually aware of the current Explore state.

---

## Wave A — Project Dashboard

### Current state

`ProjectHomeView` has a segmented `Picker` with two tabs: "Síntese" and "Arquivos". Below the picker, it shows either `ProjectSynthesisView` or `ItemsView`. There's a meatball menu with Add Item / Export. Agent suggestions were just added above the picker.

### Target state

A scrollable dashboard with sections, ordered by relevance:

```
┌──────────────────────────────────────────┐
│ ← Explore    📁 Launch Plan    [ ··· ]   │ ← toolbar unchanged
├──────────────────────────────────────────┤
│                                          │
│  ┌──────────────────────────────────┐    │
│  │ 🧠 "3 new decisions detected.   │    │ ← Agent Suggestions (já existe)
│  │    Update summary?"             │    │
│  │                [Update][Dismiss]│    │
│  └──────────────────────────────────┘    │
│                                          │
│  ── At a Glance ──────────────────      │ ← NEW Hero section
│  ┌──────────────────────────────────┐    │
│  │ 📊 12 items  ✅ 5 tasks  ⚠️ 2   │    │ ← Quick stats row
│  │ 📅 Last activity: 2h ago        │    │
│  │ 🏥 Health: ●●●○○ 72%           │    │
│  └──────────────────────────────────┘    │
│                                          │
│  ── Recent Activity ──────────────      │ ← Timeline (last 7 days)
│  ● Today — "Weekly Sync" analyzed       │
│  ● Today — Decision: "Use PostgreSQL"   │
│  ● Yesterday — Task completed: "API"    │
│  ● Yesterday — Risk flagged: "Budget"   │
│                                          │
│  ── Pending ──────────────────────      │ ← Open tasks + decisions
│  ☐ Migrate auth service (@carla)        │
│  ☐ Review budget proposal (@joão)       │
│  ☐ Decide: PostgreSQL vs MySQL          │
│                                          │
│  ── Files ────────────────────────      │ ← Condensed file list
│  📄 Weekly Sync (transcrição, 24KB)     │
│  📄 Sprint Planning (transcrição, 18KB) │
│  📄 Architecture notes (markdown, 2KB)  │
│  [View all 12 files →]                  │
│                                          │
└──────────────────────────────────────────┘
```

### Data sources for each section

| Section | Data source | Already built? |
|---|---|---|
| Agent Suggestions | `ProjectSuggestionService.pending(for:)` | ✅ Task 11-13 |
| At a Glance | `Project.healthScore`, `Project.lastActivityAt`, item/task counts | ✅ Models exist |
| Recent Activity | `ProjectTimelineView` data (filtered to 7 days, top 5 events) | ✅ Timeline exists |
| Pending | `ProjectDerivedItem` with status `.todo`/`.inProgress`, open decisions | ✅ Models exist |
| Files | `ItemsView` data (condensed to top 5, link to full list) | ✅ ItemsView exists |

### Implementation approach

- Replace the segmented `Picker` with a `ScrollView` containing section cards
- Each section is a standalone component (can be built and tested independently)
- The old "Síntese" and "Arquivos" tabs become sections in the scroll, not top-level navigation
- Navigation title gets a subtle "last updated" subtitle

### What happens to the old tabs

- "Síntese" → moves to a **Synthesis** section card in the scroll. If no synthesis exists, shows "Generate Synthesis" button (already built).
- "Arquivos" → becomes the **Files** section (condensed, top 5, link to full list).
- The segmented `Picker` and `ProjectTab` enum are removed.

---

## Wave B — Intelligent Onboarding

### Current state

New users see an empty Explore tab: "No projects yet" with a "Create Project" button. The Inbox may have items, but there's no connection between "I captured something" and "I should create a project."

### Target state

**Trigger:** When the user opens the Explore tab and:
- There are ≥3 items in Inbox without a project assignment, OR
- There are ≥2 items with similar content (semantic similarity, shared people, temporal proximity)

**Action:** Show an onboarding card at the top of the project list:

```
┌──────────────────────────────────────────┐
│ 💡 You have 3 unassigned items           │
│    about "Product Launch"                │
│                                          │
│    These look related. Create a          │
│    project to organize them?             │
│                                          │
│    [Create Project]  [Dismiss]           │
└──────────────────────────────────────────┘
```

Tapping "Create Project" opens `PromoteToProjectSheet` with those items pre-selected.

**Implementation:**
- `InboxCriticalMassDetector` — a simple heuristic service
- Checks item count without project assignment
- Optionally checks temporal proximity (items created within 7 days of each other)
- Stored as a `ProjectSuggestion` (reuse existing model!) with type `.connectionProposal` or a new `.projectCreation` type
- Card shown in `ProjectListView` when suggestions exist

**Empty state redesign:**

When there are truly no projects AND no inbox items, show a guided empty state:

```
┌──────────────────────────────────────────┐
│                                          │
│              📁                          │
│       Welcome to Wawa Note               │
│                                          │
│  Capture meetings, notes, or documents.  │
│  They become living projects with        │
│  tasks, decisions, and connections.      │
│                                          │
│  ┌──────────────────────────────────┐    │
│  │ 🎙️ Record your first meeting    │    │
│  └──────────────────────────────────┘    │
│  ┌──────────────────────────────────┐    │
│  │ ✏️  Create a note               │    │
│  └──────────────────────────────────┘    │
│  ┌──────────────────────────────────┐    │
│  │ 📁 Create an empty project      │    │
│  └──────────────────────────────────┘    │
│                                          │
└──────────────────────────────────────────┘
```

---

## Wave C — Navigation Simplification

### Current state

`ExploreView` has a segmented picker with 3 options: Projects, Files, Timeline. Files is a global `FileBrowserView` that duplicates Inbox functionality. Timeline is a global `TimelineExplorerView` that shows events across all projects — noisy and unfocused.

### Target state

Remove the segmented picker entirely. `ExploreView` shows ONLY the project list.

```
Explore tab = ProjectListView
```

The global file browser and timeline are removed from the tab. Timeline remains available inside individual projects (already built in `ProjectTimelineView`).

### Where users see files (before vs after)

| Scope | Before | After |
|---|---|---|
| **Global (Explore tab)** | FileBrowserView duplicando Inbox | ❌ Removido |
| **Global (Explore tab)** | TimelineExplorerView global | ❌ Removido |
| **Dentro do projeto** | Tab "Arquivos" no ProjectHome | ✅ Seção "Files" no dashboard + [View all →] abre lista completa |
| **Dentro do item** | KnowledgeDetailView com body.md, transcript.json, etc. | ✅ Inalterado |
| **Inbox** | InboxView com busca/filtro de itens | ✅ Inalterado |

### Changes

| Component | Action |
|---|---|
| `ExploreView` | Remove `ExploreTab` enum, remove `Picker`, remove `FileBrowserView` and `TimelineExplorerView` cases |
| `FileBrowserView` | Keep the component (used inside projects) but remove from Explore |
| `TimelineExplorerView` | Keep the component (used inside projects) but remove from Explore |
| `ContentView` | No changes to tab structure — just the Explore tab internals get simpler |

### Chat overlay context

The chat overlay already sets context based on the current tab. With Explore simplified to projects-only, the chat context becomes `context = .exploreProjects` consistently. No more ambiguity about "which Explore sub-tab am I in."

---

## Design Decisions

1. **Dashboard over file browser.** The Project Home's primary job is to show intelligence, not files. Files are secondary — accessible via a "View all" link, not a top-level tab.

2. **Reuse, don't rebuild.** Every data source for the dashboard already exists — models, services, timeline view. This is a UI composition task, not a backend task.

3. **Suggestions as the unifying pattern.** Both Agent Suggestions (Wave A) and onboarding nudges (Wave B) use the same `ProjectSuggestion` model. One card component renders both. The system doesn't distinguish between "AI found a pattern" and "system detected orphan items" — both are suggestions the user acts on.

4. **Remove before adding.** Wave C removes global Timeline and FileBrowser from Explore before Wave A adds dashboard complexity. This keeps the overall UI simpler even as individual screens get richer.

5. **Guided empty states over blank screens.** Every empty state (no projects, no items, no synthesis) should have a clear next action. Never show just an icon and a message.

## Scope Boundaries

**In scope:**
- `ProjectHomeView` redesign with scrollable dashboard sections
- `ProjectListView` onboarding card for orphan Inbox items
- Guided empty states for projects, inbox, and explore
- Removal of global Timeline and FileBrowser from Explore tab
- `ProjectSuggestion` new type: `.projectCreation`

**Out of scope:**
- Semantic similarity detection for related items (use temporal proximity only — simpler, good enough)
- Changes to the Chat overlay
- Changes to Capture or Inbox tabs
- New backend services — everything uses existing APIs
