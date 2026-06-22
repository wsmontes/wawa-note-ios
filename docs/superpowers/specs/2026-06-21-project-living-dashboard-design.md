# Project Living Dashboard — Design Spec

**Date:** 2026-06-21
**Status:** Approved
**Context:** The Project tab doesn't reveal the intelligence the system produces. The architecture (KnowledgeItems with rich analysis, ProjectDerivedItems for tasks/signals/synthesis/decisions/questions, GraphEdges with provenance, health metrics, agent suggestions) is solid — but the UI shows a file browser with some stats. The user opens a project and sees nothing that makes it feel alive.

## Problem

8 signs of a living project. 2 are visible today:
- Items entering ✅, Tasks created ✅
- Decisions extracted ❌, Risks signaled ❌, Questions visible ❌
- Connections formed ❌, Summary evolving ❌, Metrics trending ❌

## Solution: 3 Waves

### Wave 1: The Awake Project
Make the project feel alive on first visit.
- Automatic synthesis on project creation (promote) + on-demand "Update Project"
- Attention Required section: prioritized action cards
- Complete Hero card: decisions, risks, questions, connections counts
- Rich activity feed with typed events

### Wave 2: Decisions, Risks, Questions
Make every analysis output visible and actionable.
- Decision cards with confirm/reject actions
- Risk signals with suggested mitigations
- Question cards with answer/dismiss
- Provenance on every card ("From: Weekly Sync, 2d ago")

### Wave 3: Secondary Navigation
Organize specialized views that already exist.
- Segmented tabs: Overview | Kanban | Graph | Timeline | Files
- Kanban with drag-drop (exists), Graph with force layout (exists), Timeline with events (exists), Files with full list (exists)

## Scope Boundaries

**In scope:** ProjectHomeView redesign, DecisionCardView, QuestionCardView, RiskSignalView, AttentionRequired engine, automatic synthesis, secondary tab navigation, provenance display on derived items.

**Out of scope:** New backend services, AI model changes, Inbox/Capture/Chat changes, force-directed graph improvements, Kanban intelligence features (confidence rings, AI completion suggestions — Phase D from Project Intelligence Plan).

## Data Sources (all already exist)

| Data | Source | Already built? |
|------|--------|---------------|
| Item counts, task counts | `@Query` on KnowledgeItem + ProjectDerivedItem | ✅ |
| Decision items | `ProjectDerivedItem` with `type == .decision` | ✅ Task 1 |
| Risk signals | `ProjectDerivedItem` with `type == .signal` | ✅ Model exists |
| Question items | `ProjectDerivedItem` with `type == .question` | ✅ Task 1 |
| Connections | `GraphEdgeService.neighborhood()` | ✅ |
| Synthesis | `ProjectDerivedItemService.fetchSynthesis()` | ✅ |
| Health metrics | `Project.healthScore/healthStatus/lastActivityAt` | ✅ |
| Agent suggestions | `ProjectSuggestionService.pending()` | ✅ |
| Timeline events | KnowledgeItem + ProjectDerivedItem queries | ✅ |
