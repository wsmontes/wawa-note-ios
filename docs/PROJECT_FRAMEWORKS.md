# Project Frameworks & Lens System — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-197
**Source modules:** `Domain/Services/FrameworkService.swift`, `LensAnalysisService.swift`, `ai_config.json`

---

## Overview

Project frameworks enable LLM-defined, user-customizable schemas for project analysis and organization. Instead of hardcoded Swift enums, frameworks are JSON schemas that define what fields, analyses, and views a project supports. The lens system provides focused analytical perspectives on project data.

---

## Architecture

```
┌──────────────────────────────┐
│       FrameworkService        │
│  Load schemas                 │
│  Validate at runtime          │
│  Apply framework to project   │
└──────────┬───────────────────┘
           │
    ┌──────▼───────────────────┐
    │  ai_config.json           │
    │  Built-in frameworks (5)  │
    │  Built-in lenses (5)      │
    │  User custom frameworks   │
    └──────────────────────────┘
           │
    ┌──────▼───────────────────┐
    │  DynamicAnalysis          │
    │  Render UI from schema    │
    │  No hardcoded views       │
    └──────────────────────────┘
           │
    ┌──────▼───────────────────┐
    │  LensAnalysisService      │
    │  Risk lens                │
    │  Opportunity lens         │
    │  Timeline lens            │
    │  Relationships lens       │
    │  Completeness lens        │
    └──────────────────────────┘
```

---

## Framework Schema

Each framework is defined as a JSON schema in `ai_config.json`:

```json
{
  "frameworks": {
    "meeting": {
      "id": "meeting",
      "name": "Business Meeting",
      "description": "Standard business meeting analysis",
      "analysisPrompts": {
        "summary": "Extract key discussion points...",
        "decisions": "Identify decisions made...",
        "actions": "Extract action items with owners..."
      },
      "fields": [
        {"key": "meeting_type", "label": "Meeting Type", "type": "string"},
        {"key": "attendees", "label": "Attendees", "type": "string[]"},
        {"key": "duration_minutes", "label": "Duration", "type": "number"}
      ],
      "views": ["timeline", "kanban", "graph"],
      "defaultLens": "risk"
    },
    "research": {
      "id": "research",
      "name": "Research Interview",
      "description": "User research and interview analysis",
      "analysisPrompts": {
        "summary": "Extract research findings...",
        "insights": "Identify key insights and patterns...",
        "quotes": "Extract notable verbatim quotes..."
      },
      "fields": [
        {"key": "participant_role", "label": "Participant Role", "type": "string"},
        {"key": "methodology", "label": "Methodology", "type": "string"},
        {"key": "confidence", "label": "Finding Confidence", "type": "number"}
      ],
      "views": ["timeline", "graph"],
      "defaultLens": "relationships"
    }
  }
}
```

---

## 5 Built-in Frameworks

| Framework | Purpose | Key Analysis Focus | Default Lens |
|---|---|---|---|
| `meeting` | Business meetings | Decisions, action items, owners, dates | risk |
| `research` | Research interviews | Insights, evidence, methodology, quotes | relationships |
| `brainstorm` | Ideation sessions | Ideas, connections, opportunities, themes | opportunity |
| `journal` | Personal journal | Reflections, patterns, growth, sentiment | timeline |
| `blank` | Generic / custom | Pure extraction, no special instructions | completeness |

---

## FrameworkService

Manages framework lifecycle:

```swift
class FrameworkService {
    // Load all frameworks (built-in + user custom)
    func loadFrameworks() -> [ProjectFramework]

    // Get framework by ID
    func framework(id: String) -> ProjectFramework?

    // Apply framework to project
    func applyFramework(_ framework: ProjectFramework, to project: Project)

    // Validate custom framework schema
    func validateCustomFramework(_ json: String) throws -> ProjectFramework
}
```

### Schema loading chain
1. Bundle `ai_config.json` (built-in, always available)
2. User overrides: `configs/frameworks/*.json` (VFS-accessible)
3. Per-project: stored in `Project.frameworkJSON`
4. Validation: JSON Schema validation before saving

---

## DynamicAnalysis

Renders project analysis UI from framework schema — no hardcoded views.

### How it works
1. Framework defines `fields` array with key, label, type
2. `DynamicAnalysis` reads schema at runtime
3. Generates SwiftUI form fields:
   - `string` → TextField
   - `number` → Stepper/NumberFormatter TextField
   - `string[]` → Tag editor
   - `boolean` → Toggle
   - `date` → DatePicker
4. Values stored in `Project.frameworkJSON` as key-value pairs

### UI generation
```swift
@ViewBuilder
func fieldView(for field: FrameworkField, value: Binding<Any>) -> some View {
    switch field.type {
    case "string": TextField(field.label, text: stringBinding(value))
    case "number": TextField(field.label, value: doubleBinding(value), format: .number)
    case "string[]": TagEditorView(label: field.label, tags: arrayBinding(value))
    case "boolean": Toggle(field.label, isOn: boolBinding(value))
    case "date": DatePicker(field.label, selection: dateBinding(value))
    default: TextField(field.label, text: .constant(""))
    }
}
```

---

## Lens System

LensAnalysisService provides 5 focused analytical perspectives that can be applied to any project.

### 1. Risk Lens
**Purpose:** Identify and assess project risks.
- Scans tasks for overdue/deadline items
- Analyzes signals for risk-type AgentSuggestions
- Checks item freshness (stale items → risk)
- Output: risk score 0-100 + risk register items

### 2. Opportunity Lens
**Purpose:** Identify positive patterns and opportunities.
- Scans signals for opportunity-type suggestions
- Detects recurring themes across items
- Identifies underutilized connections
- Output: opportunity score + suggested actions

### 3. Timeline Lens
**Purpose:** Analyze temporal patterns in project data.
- Charts item and task creation over time
- Identifies activity gaps (>7 days idle → alert)
- Projects future completion dates based on velocity
- Output: timeline visualization + bottleneck alerts

### 4. Relationships Lens
**Purpose:** Analyze the graph structure of project entities.
- Identifies isolated items (no edges)
- Finds central/hub entities (most connected)
- Detects weak clusters (low edge density)
- Output: graph metrics + connection recommendations

### 5. Completeness Lens
**Purpose:** Check project data quality and completeness.
- Verifies all items have transcript or analysis
- Checks for missing metadata (owners, dates)
- Identifies empty sections (no tasks, no edges)
- Output: completeness score + gap list

### Lens application
```swift
// From AgentLoop or chat
run_command "ls /projects/my-project | lens risk"
run_command "ls /projects/my-project | lens relationships"
```

---

## Custom Framework Creation

Users can create custom frameworks via the Config Project VFS:

```bash
# Via chat agent
run_command "touch /config/schemas/legal-review.json --title 'Legal Review' --fields 'case_number,parties,jurisdiction,filing_deadline'"
```

This creates a new framework JSON in `configs/frameworks/legal-review.json` that is immediately available for project application.

---

## Framework → Pipeline Integration

When `ContentPipelineService.process()` runs on an item assigned to a framework-enabled project:

1. Framework's `analysisPrompts` are injected into the system prompt
2. AgentLoop receives framework-specific instructions
3. `SelectSchemaTool` validates the framework schema
4. `WriteAnalysisTool` writes analysis in framework-compatible format
5. Framework fields are extracted and stored in `Project.frameworkJSON`

---

## Future: FlexibleProjectFramework

The memory file `wave25_flexible_projects.md` describes a more ambitious vision:
- Completely LLM-authored frameworks (schemas, prompts, views)
- Framework marketplace / sharing
- Auto-detection: LLM suggests framework based on project content
- Framework versioning and migration

Current implementation provides the foundation (JSON schemas, DynamicAnalysis, Lens system) but not the marketplace or auto-detection.
