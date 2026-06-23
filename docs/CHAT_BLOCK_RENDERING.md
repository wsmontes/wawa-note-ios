# Chat Block Rendering System — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-192, KAN-9, KAN-46
**Source modules:** `UI/Chat/ChatBlockViews.swift`, `Domain/Models/ChatModels.swift`

---

## Overview

The chat system renders LLM output as structured blocks rather than raw markdown. When the agent (or a pipeline tool) produces output, it is parsed into typed blocks. Each block type has a dedicated SwiftUI view builder. Blocks are streamed incrementally — partial blocks render as tokens arrive.

---

## Architecture

```
LLM Response (streaming tokens)
        │
        ▼
ContentParser (heuristic markdown → blocks)
        │
        ▼
ChatBlock array (ordered, typed)
        │
        ▼
ChatBlockViews (SwiftUI rendering)
        │
        ├── Text: formatted markdown in Text
        ├── Table: LazyVGrid with headers
        ├── Code: monospace with syntax highlight
        ├── TaskCard: kanban card with status
        ├── ItemCard: item preview with metadata
        ├── ProjectContext: colored badge with project name
        ├── SearchResults: result list with relevance
        ├── AnalysisAccordion: collapsible sections
        ├── ChoicePrompt: interactive buttons
        ├── Confirmation: yes/no dialog
        ├── FileLink: tappable file reference
        ├── DocumentHeader: title + metadata
        ├── FreeTextInput: text field for user input
        ├── ProgressUpdate: progress bar with status
        ├── BulletList: bullet-point list
        ├── OrderedList: numbered list
        ├── Table (dataframe): dense data grid
        ├── custom: user-defined block type
        └── (raw): unparsed fallback
```

---

## ChatBlock Model

```swift
// ChatModels.swift
struct ChatBlock: Codable, Identifiable {
    let id: String
    let type: ChatBlockType
    let content: String              // Primary text content
    let metadata: [String: String]?  // Type-specific metadata
    let children: [ChatBlock]?       // Nested blocks (lists, accordion)
    let isStreaming: Bool            // True while tokens arriving
}

enum ChatBlockType: String, Codable {
    case text, table, code, bulletList, orderedList
    case projectContext, taskCard, itemCard
    case searchResults, analysisAccordion
    case choicePrompt, confirmation
    case fileLink, documentHeader
    case freeTextInput, progressUpdate
    // 18 types total
}
```

---

## Block Type Reference

### 1. Text
**Purpose:** Rich formatted text with inline markdown.

```json
{
  "type": "text",
  "content": "Here's a **bold** point and an *italic* note.\n\nNew paragraph with [link](url)."
}
```

**Rendering:** Markdown → AttributedString in SwiftUI `Text`. Supports: **bold**, *italic*, `code`, [links], ~~strikethrough~~, headings.

### 2. Table
**Purpose:** Structured data display with headers.

```json
{
  "type": "table",
  "metadata": {
    "headers": "Name | Role | Status",
    "alignment": "left,left,center"
  },
  "children": [
    { "type": "text", "content": "Wagner | Engineer | Active" },
    { "type": "text", "content": "Maria | Designer | Away" }
  ]
}
```

**Rendering:** `LazyVGrid` with header row, alternating backgrounds, horizontal scroll.

### 3. Code
**Purpose:** Syntax-highlighted code blocks.

```json
{
  "type": "code",
  "content": "func hello() {\n    print(\"world\")\n}",
  "metadata": { "language": "swift" }
}
```

**Rendering:** Monospace font (`.system(.caption, design: .monospaced)`), dark background, copy button, language badge.

### 4. BulletList
**Purpose:** Unordered list items.

```json
{
  "type": "bulletList",
  "children": [
    { "type": "text", "content": "First point" },
    { "type": "text", "content": "Second point with **bold**" }
  ]
}
```

### 5. OrderedList
**Purpose:** Numbered list items.

```json
{
  "type": "orderedList",
  "children": [
    { "type": "text", "content": "Step one" },
    { "type": "text", "content": "Step two" }
  ]
}
```

**Rendering:** Numbered items with `.orderedList` style. Supports nested lists.

### 6. ProjectContext
**Purpose:** Displays active project context badge at top of chat.

```json
{
  "type": "projectContext",
  "content": "My Project",
  "metadata": {
    "projectId": "uuid",
    "colorHex": "#FF6B35",
    "itemCount": "12"
  }
}
```

**Rendering:** Colored pill/badge with project name, icon, item count. Tapping navigates to project.

### 7. TaskCard
**Purpose:** Displays a task in card format with status and priority.

```json
{
  "type": "taskCard",
  "content": "Implement authentication flow",
  "metadata": {
    "taskId": "uuid",
    "status": "In Progress",
    "priority": "High",
    "owner": "Wagner",
    "dueDate": "2026-06-30"
  }
}
```

**Rendering:** Card with priority color stripe, status badge, owner avatar, due date. Tapping opens task editor.

### 8. ItemCard
**Purpose:** Displays a KnowledgeItem preview with metadata.

```json
{
  "type": "itemCard",
  "content": "Q2 Planning Meeting",
  "metadata": {
    "itemId": "uuid",
    "type": "audio",
    "duration": "45m",
    "date": "2026-06-15",
    "projectName": "Q2 Initiative"
  }
}
```

**Rendering:** Card with type icon, duration, date, project badge. Tapping opens item detail.

### 9. SearchResults
**Purpose:** Displays search results from agent tool use.

```json
{
  "type": "searchResults",
  "content": "Found 3 items matching 'quarterly'",
  "children": [
    { "type": "itemCard", "content": "...", "metadata": {...} },
    { "type": "itemCard", "content": "...", "metadata": {...} }
  ]
}
```

**Rendering:** Header with result count, scrollable list of ItemCards.

### 10. AnalysisAccordion
**Purpose:** Collapsible sections for structured analysis output.

```json
{
  "type": "analysisAccordion",
  "content": "Meeting Analysis",
  "children": [
    { "type": "text", "content": "**Summary:** Q2 planning...", "metadata": {"section": "Summary", "expanded": "true"} },
    { "type": "text", "content": "**Decisions:** ...", "metadata": {"section": "Decisions"} },
    { "type": "text", "content": "**Action Items:** ...", "metadata": {"section": "Action Items"} },
    { "type": "text", "content": "**Risks:** ...", "metadata": {"section": "Risks"} }
  ]
}
```

**Rendering:** `DisclosureGroup` per child, section header with expand/collapse chevron. Summary section expanded by default.

### 11. ChoicePrompt
**Purpose:** Interactive buttons for user decision.

```json
{
  "type": "choicePrompt",
  "content": "How should I categorize this meeting?",
  "children": [
    { "type": "text", "content": "Planning", "metadata": {"action": "categorize:planning"} },
    { "type": "text", "content": "Review", "metadata": {"action": "categorize:review"} },
    { "type": "text", "content": "Status Update", "metadata": {"action": "categorize:status"} }
  ]
}
```

**Rendering:** Question text + button group. Tapping a button calls back with the action value.

### 12. Confirmation
**Purpose:** Yes/no confirmation dialog.

```json
{
  "type": "confirmation",
  "content": "Create 3 tasks from this analysis?",
  "metadata": {
    "confirmAction": "create_tasks",
    "confirmPayload": "{...}"
  }
}
```

**Rendering:** Warning text + "Cancel" (gray) + "Confirm" (accent) buttons.

### 13. FileLink
**Purpose:** Tappable reference to an artifact file.

```json
{
  "type": "fileLink",
  "content": "audio.m4a",
  "metadata": {
    "itemId": "uuid",
    "filePath": "items/uuid/audio.m4a",
    "fileSize": "12.3 MB",
    "mimeType": "audio/x-m4a"
  }
}
```

**Rendering:** File icon + name + size. Tapping opens file or shares.

### 14. DocumentHeader
**Purpose:** Title and metadata for a document/export preview.

```json
{
  "type": "documentHeader",
  "content": "Q2 Planning Meeting Analysis",
  "metadata": {
    "author": "Wawa Note AI",
    "date": "2026-06-22",
    "format": "Markdown"
  }
}
```

**Rendering:** Large title + subtitle with author/date. Used for export previews.

### 15. FreeTextInput
**Purpose:** Text field for user to provide input to the agent.

```json
{
  "type": "freeTextInput",
  "content": "What should I name the new project?",
  "metadata": {
    "inputId": "name_project",
    "placeholder": "Project name...",
    "maxLength": "100"
  }
}
```

**Rendering:** Prompt text + TextField with submit button. Submitting sends response back to agent.

### 16. ProgressUpdate
**Purpose:** Progress bar for long-running operations.

```json
{
  "type": "progressUpdate",
  "content": "Analyzing meeting transcript...",
  "metadata": {
    "current": "3",
    "total": "7",
    "phase": "Extracting entities",
    "percentComplete": "42"
  }
}
```

**Rendering:** Progress bar (`.progressViewStyle(.linear)`), phase label, current/total.

### 17. (Reserved for future types)
### 18. custom
**Purpose:** User-defined block type for extensibility.

```json
{
  "type": "custom",
  "content": "Any content",
  "metadata": {
    "customType": "dashboard_card",
    "renderHint": "compact"
  }
}
```

---

## Streaming Architecture

### Incremental rendering
1. LLM emits token → appended to message content
2. ContentParser runs on accumulated text
3. Partial ChatBlocks created if parser detects structure (table pipe, code fence, list marker)
4. `isStreaming: true` → block renders with shimmer/pulse animation
5. On message complete → `isStreaming: false` → final render

### Parser heuristic (ContentParser)
- Detects table: `| ... | ... |` pattern → splits into headers + rows
- Detects code: ` ``` ` fence open/close → code block
- Detects bullet list: lines starting with `- ` or `* `
- Detects ordered list: lines starting with `1. ` `2. `
- Detects action items: lines starting with `- [ ] ` or `- [x] `
- Detects decisions: lines starting with `**Decision:**`
- Passes through everything else as `text` blocks

### Block builder
Takes parsed segments → constructs `ChatBlock` array with proper nesting:
- Top-level: sequential block list
- Nested: lists contain child blocks
- Sibling grouping: consecutive same-type blocks may merge

---

## Adding a New Block Type

1. Add case to `ChatBlockType` enum in `ChatModels.swift`
2. Add JSON schema for the block type
3. Add parser heuristic in `ContentParser.swift`
4. Add view builder in `ChatBlockViews.swift`:

```swift
@ViewBuilder
func blockView(for block: ChatBlock) -> some View {
    switch block.type {
    case .text: TextBlockView(block)
    case .table: TableBlockView(block)
    // ... add new case
    case .myNewType: MyNewBlockView(block)
    }
}
```

5. Add unit test for parser detection and view rendering

---

## Performance

| Metric | Value |
|---|---|
| Parser latency | <5ms per 1KB of markdown |
| Block count per message | 1-50 typical |
| Streaming update frequency | Per token (60Hz max) |
| View recycling | Uses List with ForEach for scroll performance |
| Memory per block | ~2KB (model + view state) |
