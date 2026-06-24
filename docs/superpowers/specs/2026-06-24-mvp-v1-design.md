# Wawa Note MVP V1 — Design Spec

> **Date:** 2026-06-24 | **Epic:** KAN-518 | **Branch:** feat/mvp-v1

## Product Direction

After intensive usage review, the product is being simplified for App Store launch. Focus shifts from complex multi-item project analysis to simple, reliable item capture + analysis, with projects serving as organizational folders. Chat is scoped to project context only.

## Navigation

```
Capture | Inbox | Explore   ← 3 tabs (Chat removed from tab bar)
```

- **Capture:** Record, scan, import — create source items
- **Inbox:** Search, triage, review all items
- **Explore:** List of projects (folders)

## Project Detail (3 tabs)

```
┌─────────────────────────────────────┐
│ Project Name                    [⋯] │
├─────────────────────────────────────┤
│  [Chat]   [Items]   [Files]         │ ← segmented control
├─────────────────────────────────────┤
│                                     │
│  Chat: Agent scoped to this project │
│  Items: Chronological + filters     │
│  Files: Raw files + export          │
│                                     │
└─────────────────────────────────────┘
```

| Tab | Purpose | Content |
|---|---|---|
| **Chat** (1st) | AI agent scoped to project items only | Scoped chat, agent sees only this project's items |
| **Items** (2nd) | Chronological list with derivatives | Segmented: All Items / Action Items / Questions |
| **Files** (3rd) | Raw file browser | Audio, transcripts, JSONs, images — all exportable |

## Item Analysis (Simplified)

- **Single schema:** `MeetingAnalysis` for all item types
- **Fields:** summary, decisions, action_items, risks, open_questions, entities, important_dates
- **One JSON:** `analysis.json` per item
- **No framework templates:** research, brainstorm, journal, coaching, legal, product — removed
- **User-editable:** toggle fields on/off via Settings
- **Isolated:** agent sees only the item being analyzed

## Removed (from current codebase)

| Component | Reason |
|---|---|
| Chat tab (4th tab) | Chat only in project context |
| ProjectAgent | No project-level processing |
| ProjectIngestionPipeline | No synthesis/ingestion |
| Framework templates (6) | Single schema for all |
| ProjectSynthesisView + cards | No synthesis |
| ProjectDerivedItem type .synthesis | No synthesis |
| Global chat context | Scoped only |

## Kept (unchanged)

- Capture tab (recording, scanning, import)
- Inbox tab (search, triage, filters)
- Explore tab (project list)
- KnowledgeDetailView (item detail with analysis)
- All importers (10 formats)
- All exporters (Markdown, JSON, SRT, VTT, CSV)
- Transcription (Apple + Whisper)
- Provider abstraction (OpenAI, Anthropic, Gemini)
- SwiftData models (KnowledgeItem, Project, TaskItem, etc.)

## Implementation

- **Branch:** `feat/mvp-v1` (created from current `feat/project-creation-update-journeys`)
- **JIRA Epic:** KAN-518
- **Child issues:** KAN-519 to KAN-528 (10 tasks)
- **Related:** KAN-259 (UX Review)
