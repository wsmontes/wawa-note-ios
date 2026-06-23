# KAN-256 Spike: Items Tab — Aggregated Project Data as Cards

> Spike date: 2026-06-23 | Status: Complete | Recommendation: Approach A (Flat Aggregation)

## Context

The Project detail view currently has 2 tabs: "Synthesis" (rich cards, KAN-255) and "Arquivos" (file browser). The request is a new "Items" tab showing cumulated/aggregated data from all project items displayed as cards.

**Existing data available:** `ProjectDerivedItem` objects with types: `task`, `signal`, `connection`, `decision`, `question`. Each has title, status, priority, body, source item references, and timestamps.

---

## Approach A: Flat Aggregation (Recommended)

**Concept:** Query all `ProjectDerivedItem` objects for the project, group by type, display each as a typed card in a single scrollable list with a segmented filter.

**Cards per type:**
- **Task cards:** Reuse existing `TaskCardView` from ChatBlockViews (already has swipe actions, priority badge)
- **Signal cards:** New compact card with icon + severity color + source reference
- **Decision cards:** New card with date + context + confidence
- **Question cards:** New card with source item attribution
- **Connection cards:** New card showing source → target with edge type

**UI:** `Picker("Filter", selection: $filter)` segmented control at top, scrollable `LazyVStack` of cards below. Filters: All, Tasks, Signals, Decisions, Questions. Each card shows source item name as a tappable link.

```
┌─────────────────────────────────┐
│ [All] [Tasks] [Signals] [Dec...]│  ← segmented filter
├─────────────────────────────────┤
│ ✅ Review Q3 roadmap   📋Todo   │  ← TaskCardView (reused)
│    From: Sprint Planning        │
├─────────────────────────────────┤
│ ⚠️ Budget risk identified       │  ← Signal card (new)
│    🔴 Risk · From: Finance doc  │
├─────────────────────────────────┤
│ 📋 Switch to Next.js   ✓ Done   │  ← Decision card (new)
│    From: Tech Review · Oct 14   │
└─────────────────────────────────┘
```

**Technical feasibility:** HIGH. All data already exists in `ProjectDerivedItem`. `TaskCardView` already exists and works. Signal/Decision/Question cards are simple VStack views (~30 lines each). No schema changes. Zero new data models.

**Effort:** 2-3 hours implementation. Mostly new SwiftUI views + query in existing `ProjectDerivedItemService`.

**Duplicates handling:** Sort by `createdAt`; show source item name for attribution. No dedup needed at this level.

**Pros:** Quick to implement, leverages existing UI components, clearly attributable to source items, filterable.

**Cons:** Flat list can be long for large projects. No cross-item relationships visible (that's the Synthesis tab's job).

---

## Approach B: Timeline View

**Concept:** Display all project items and their derived artifacts on a chronological timeline, grouped by date.

**UI:** `TimelineView` similar to existing calendar timeline but focused on project items. Vertical timeline with date headers, cards pinned to each date. Tappable cards expand to show details.

**Technical feasibility:** MEDIUM. Existing `TimelineEntry` model and `ProjectTimelineView` provide patterns. Would need to adapt to show `ProjectDerivedItem` alongside `KnowledgeItem`. Timeline layout with variable card heights is complex on mobile.

**Effort:** 1-2 weeks. Significant new layout code, complex date grouping logic.

**Pros:** Shows temporal relationships, natural for project history, visually appealing.

**Cons:** High effort for experimental tab, timeline doesn't suit all artifact types (signals, questions don't have strong temporal meaning), mobile space constraints.

---

## Approach C: Category Cards with Count Badges

**Concept:** Instead of listing individual items, show category summary cards with counts and top-N items. Similar to iOS Health app's category view.

**UI:** Grid of category cards:
```
┌──────────────┐ ┌──────────────┐
│    Tasks     │ │   Signals    │
│      12      │ │      5       │
│ ⚠️ 3 overdue │ │ 🔴 2 risks   │
│ [View all]   │ │ [View all]   │
└──────────────┘ └──────────────┘
┌──────────────┐ ┌──────────────┐
│  Decisions   │ │  Questions   │
│      3       │ │      7       │
│ ✓ 2 resolved│ │ ? 4 open      │
└──────────────┘ └──────────────┘
```
Tapping a category pushes to a filtered list view (Approach A).

**Technical feasibility:** HIGH. Simple grid layout, counts from `ProjectDerivedItemService`, pushes to filtered list.

**Effort:** 4-6 hours. Grid layout + navigation + filtered list.

**Pros:** Clean overview, scannable, scales well for large projects.

**Cons:** Two taps to see details, less immediately informative than flat list.

---

## Recommendation: Approach A (Flat Aggregation)

**Rationale:**
1. **Already have the cards:** `TaskCardView` exists. Signal/Decision/Question cards are simple.
2. **Matches the Synthesis tab pattern:** Both tabs show card-based content from the same data.
3. **Lowest effort, highest value:** 2-3 hours for a fully functional tab.
4. **Complements Synthesis:** Synthesis shows AI-generated narrative. Items tab shows raw extracted data with source attribution.
5. **Approach C can be a future enhancement** (add category overview as the default, with tap-to-expand).

**Implementation (post-spike):**
- Add `case items = "Items"` to `ProjectTab` enum
- New `ProjectItemsView` similar to `ProjectSynthesisView`
- Query `ProjectDerivedItemService.fetch(for: projectID)`
- Group by `ProjectDerivedType`
- Render with `TaskCardView` + 3 new card types
- Add `"Arquivos"` → `"Files"` (Portuguese fix, KAN-249)
- Add segmented filter control

**Files to create/modify:**
- Modify: `ProjectDetailView.swift` — add tab case + tab view
- Modify: `ProjectDetailView.swift` — new `ProjectItemsView`, card views
- Reuse: `ChatBlockViews.swift` — `TaskCardView`

**Tab order recommendation:**
Synthesis | **Items** | Files
