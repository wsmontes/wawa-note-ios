# Wawa Note — Kiro Review

Date: 2026-06-11
Author: Wagner Montes (self-review)
Scope: Full-stack review — code quality, architecture, product strategy, and development roadmap.

---

## Part 1: Deep Critical Review

State: 139 commits, v1.0.0 released 2026-06-05, solo developer, AI-assisted.

### Problem 1: Testing is cosmetic — the critical paths are completely unverified

**Current state:** 27 tests exist. They test that enum cases exist, that trivial getters return default values, and that hardcoded vectors produce expected cosine similarity. None exercise actual behavior. All 27 would pass even if the app was completely broken.

**What's actually dangerous and untested:**

- **ShellInterpreter** (700+ lines) — handles all agent commands. The `tokenize` function does manual quote parsing, flag extraction, and redirect detection. The `splitCommands` function splits by `&&`, `;`, and newlines with quote-awareness. Edge cases:
  - Nested quotes: `echo '{"key": "value with \"quotes\""}' > path`
  - `&&` inside quoted strings
  - Flags that look like paths: `--status /done`
  - The CHANGELOG already documented parsing bugs here

- **ContentPipelineService.processEntry** — had a P0 double-resume crash (the fix prevents it, but `resumed` flag isn't atomic and relies on `@MainActor` isolation)

- **AgentLoop** core iteration loop — the primary differentiating feature of the app, never unit-tested

**Concrete test proposals:**

1. ShellInterpreter tokenizer edge cases (quoted redirect, split commands with quoted ampersand, flag parsing not consuming paths as values)
2. ContentPipelineService double-resume prevention and graceful timeout
3. AgentLoop tool dispatch cycle (tool call → execute → continue → finish)
4. Pipeline infinite loop prevention (don't reprocess analyzed items)
5. Import/export roundtrip (MarkdownImporter → MarkdownExporter)

### Problem 2: Feature surface area is dangerously wide for sustained maintenance

**ContentPipelineService.swift** alone is ~1200 lines containing 17 services and systems:

| Service | User value | Maintenance cost | Verdict |
|---|---|---|---|
| ContentPipelineService | Core | High | Keep |
| LensCatalogService (8 lenses) | Medium | Medium | Reduce to 3 |
| FrameworkService (8 frameworks) | Most users use 1-2 | High collectively | Ship 3, add later |
| ProjectHealthEngine | Medium | Low | Keep |
| PromptStore | Core | Low | Keep |
| AgentMemoryStore | Zero (unwired) | Low | Wire or delete |
| FieldAuthorityService | Low | Low | Keep |
| SignalPriorityService | Low | Low | Keep |
| SignalResolutionService | Low | Low | Keep |
| VersioningService (snapshot/restore) | Zero (untested, dangerous) | High | Keep record, remove restore |
| QueuePriorityService | Low | Low | Keep |
| ProcessingQueueService | Medium | Medium | Keep |
| OntologyInertiaService | Imperceptible | Low | Remove |
| PresetExportService | Low | Low | Keep |
| ContentParser | Medium | Low | Keep |
| JSSandbox + WawaJSBridge | Speculative (no evidence of use) | High (security) | Cut or defer |
| SkillTemplate | Dead code | Low | Remove until wired |

**Principle:** Ship 30% of the features at 90% quality, not 90% of features at 30% quality.

**Cut list for v1.0:**
- Remove JSSandbox, WawaJSBridge, SkillTemplate
- Remove OntologyInertiaService
- Remove VersioningService.restore() — keep recordChange() for audit trail
- Reduce frameworks to 3: Meeting, Blank, Research
- Remove Watch Connectivity and MotionActivity context sensor
- Split ContentPipelineService.swift into at least 5 files

### Problem 3: No validation through sustained real use

**Core product hypothesis:** "Meeting evidence → AI pipeline → structured knowledge graph → useful for retrieval and decision-making."

**Three major unknowns:**
1. Does the AI pipeline produce useful graphs or noise?
2. Is the agentic chat actually useful vs. direct UI navigation?
3. Does the provenance discipline matter in practice?

**Evidence this hasn't happened:**
- "Phase 8 device validation — never tested on iPhone 14 Plus hardware" (from CLAUDE.md)
- Semantic search literally returns "Results will be available when embeddings are processed"
- AgentMemoryStore exists but the agent never calls `search()` before processing
- SkillTemplate.builtIn defines 3 sub-agent templates that are never spawned

**Proposal: 2-week dogfooding protocol** — use the app daily with real data, track in `DOGFOODING.md`.

### Problem 4: Over-documentation for current project maturity

**The imbalance:**

| Activity | Investment | Output |
|---|---|---|
| Architecture docs | 12+ documents | Beautiful design descriptions |
| Implementation plans | 5 waves documented | Growing roadmap |
| Expert panel review | Full document | Hypothetical feedback |
| Actual tests | 27 | Trivial enum checks |
| Actual users | 0 | No validation data |
| Device testing | 0 | No real-world verification |

**Documentation diet:**
- Keep: README.md, CLAUDE.md, DECISIONS.md, CODING_STANDARDS.md
- Archive: CONTRIBUTING.md, CODE_OF_CONDUCT.md, expert_panel_review.md
- Add: DOGFOODING.md, KNOWN_ISSUES.md, TEST_PLAN.md

### Problem 5: AI-generated architecture patterns that exist but aren't exercised

**Dead architecture examples:**
- **AgentMemoryStore** — write-only log, agent never queries it before processing
- **8 built-in frameworks** — Legal framework has "case_citations" and "privilege_concerns" fields; no user records depositions on iPhone
- **SkillTemplate** — 3 sub-agent templates defined, never spawned by AgentLoop
- **SemanticSearchService** — exists, unwired, shell command returns placeholder text
- **JSSandbox + WawaJSBridge** — full JS execution environment with custom libraries, no evidence LLMs produce useful JS against custom API

**Rule:** If a system has no UI surface and no call site in a hot path, it's a comment, not code. Delete it or wire it.

### Problem 6: No error recovery UX story — the trust problem

**Five failure scenarios with no documented recovery path:**

1. **Provider fails mid-pipeline** — item gets `status = .failed`, unclear if user can retry manually
2. **LLM produces invalid JSON** — retry once with different strategy, then item stays `.failed` forever; error messages are developer-facing
3. **Recording interrupted at minute 45** — unclear if partial audio is recoverable
4. **OCR produces garbage** — no confidence check before analysis, no "review & edit" gate
5. **Graph produces nonsensical connections** — no "Did the AI get this wrong?" button, no edge confidence scoring

**Concrete proposals:**
1. Define error states explicitly in UI — clear contract for what user sees and can do
2. Add "manual override" escape hatch for every automated step
3. Never lose raw data (verify partial audio recovery)
4. Surface confidence with visual indicators (✓ confident, ~ review suggested, ? uncertain)
5. Implement "quarantine" pattern — AI-generated edges/tasks go to pending review before main graph

---

## Part 2: Code Smells & Dangerous Patterns

Severity scale: 🔴 Will crash in production | 🟠 Silent data corruption or race condition | 🟡 Maintenance hazard or design smell

### 🔴 1. Force-unwraps in the agent's write path (`try!`) ✅ FIXED 2026-06-12

**Location:** `ShellInterpreter.handleTouch()`

```swift
// Creating items — force unwrap
let item = try! svc.createItem(type: kt, title: t, bodyText: body, tags: tags, inboxDate: Date())

// Creating tasks — force unwrap
let task = try! TaskService(context: ctx.modelContext).create(
    title: t, projectID: pid, priority: prio, ownerName: owner, dueAt: due, createdBy: .llm
)
```

These are in the hot path of the agent — every time the LLM says `touch tasks/ --title "something"`, this runs. If the SwiftData context is in a bad state, this crashes immediately. The LLM controls when these are called.

**Also in:** `ContentPipelineService.processEntry()`:
```swift
try! KnowledgeItemService(context: ctx.modelContext).fetchItem(id: itemID)!
```

**Fix:** Replace with `guard let` and return structured errors. Every `try!` in a path reachable by AI output is a ticking bomb.

### 🔴 2. ToolContext is `@unchecked Sendable` with unprotected mutable state ✅ FIXED 2026-06-12

**Location:** `ToolContext.swift`

```swift
final class ToolContext: @unchecked Sendable {
    let modelContext: ModelContext
    var activeProjectID: UUID?       // mutated from agent loop
    var activeProjectName: String?   // mutated from agent loop
    var activeProjectSlug: String?   // mutated from agent loop
    var activeItemID: UUID?          // mutated from agent loop
    var contextKey: String?          // mutated from ShellInterpreter
    var isPlanning: Bool = false     // mutated from agent loop
    var planTaskIDs: [UUID] = []     // mutated from agent loop
}
```

Passed to AgentLoop which runs in a Task. ShellInterpreter mutates these on `@MainActor`, ChatViewModel reads them back after stream finishes. `@unchecked Sendable` lies to the compiler — nothing enforces the `@MainActor` chain.

**Fix:** Make ToolContext explicitly `@MainActor`, or use an actor with proper locking.

### 🔴 3. AgentLoop is `@unchecked Sendable` — hides real concurrency issues ✅ FIXED 2026-06-12

**Location:** `AgentLoop.swift`

AgentLoop captures ToolContext (mutable, `@unchecked Sendable`) and AgentToolRegistry (contains tools that access model context). It's created on `@MainActor` but its `runStreaming` and `runAutonomous` methods spawn Tasks. Two concurrent loops would share the same ToolContext state.

### 🟠 4. Massive code duplication: `sendMessage()` ≈ `sendInternalMessage()`

**Location:** `ChatViewModel.swift` — ~80 lines each, nearly identical. Bug fixes in one method don't propagate to the other. The CHANGELOG's "P1: Cancelled stream race condition" fix may only be in one method.

**Fix:** Extract into `executeAgentLoop(text:conversationId:isInternal:)`.

### 🟠 5. No deinit cleanup — tasks leak ✅ FIXED (already existed)

**Location:** `ChatViewModel.swift`

```swift
private var streamTask: Task<Void, Never>?
private var greetingTask: Task<Void, Never>?
```

No `deinit` that cancels these. If ChatViewModel is deallocated while a stream is running, the Task continues executing, holding a strong reference to ToolContext → ModelContext.

**Fix:** Add `deinit { streamTask?.cancel(); greetingTask?.cancel() }`.

### 🟠 6. `Task.detached` for greeting generation — wrong pattern ✅ FIXED (already uses Task{})

**Location:** `ChatViewModel.pregenerateGreeting()`

`Task.detached` creates a task that doesn't inherit actor context or priority. The `[weak self] + await MainActor.run` dance is unnecessary boilerplate.

**Fix:** Use `Task { }` (inherits actor) instead of `Task.detached { }`.

### 🟠 7. Raw strings for enums everywhere — silent corruption

**Location:** `ProjectModels.swift`

```swift
@Model final class TaskItem {
    var statusRaw: String      // "todo", "inProgress", "done", "cancelled"
    var priorityRaw: String    // "low", "medium", "high", "critical"
}
```

The LLM can write any string. `"DONE"` ≠ `"done"` → `TaskStatus(rawValue:)` returns nil → defaults to `.todo`. No error raised.

**Fix:** Validate before storing. Return error with list of valid values.

### 🟠 8. GraphEdge has no referential integrity

**Location:** `ProjectModels.swift`

Edges point to items/tasks via UUID with no `@Relationship` constraints. When an item is deleted, dangling edges remain. `rm` and task deletion don't clean up related edges.

**Fix:** In TrashService and TaskService delete paths, query and remove related edges.

### 🟠 9. No request timeout handling or retry in the provider

**Location:** `OpenAICompatibleProvider.swift`

Timeout is set (180s request, 300s resource) but no retry on 429/500/502/503, no exponential backoff, no request deduplication. 180-second timeout is extreme for interactive chat.

**Fix:** Add retry loop with exponential backoff for transient errors.

### 🟠 10. Manual JSON construction bypasses type safety

**Location:** `OpenAICompatibleProvider.send()`

The file defines a `ChatCompletionRequest` Encodable struct — and never uses it. The entire request is built with `[String: Any]` dictionaries and `JSONSerialization`. The struct is dead code.

**Fix:** Either use the Encodable struct with custom `encode(to:)` for conditional fields, or delete the dead struct.

### 🟡 11-16: Maintenance hazards

| # | Issue | Location |
|---|---|---|
| 11 | 17 services in one file | ContentPipelineService.swift (~1500 lines) |
| 12 | 500+ lines, 15 `@Published` properties | ChatViewModel.swift |
| 13 | Greeting pregeneration costs real API calls | ChatViewModel |
| 14 | `handleVision` blocks main thread with `DispatchSemaphore` | ShellInterpreter |
| 15 | Notification-based pipeline completion is fragile | ContentPipelineService |
| 16 | SearchService instantiated without `fileStore` parameter | ChatViewModel |

### Summary: The 5 Worst Things

| # | Issue | Severity | Effort to fix |
|---|---|---|---|
| 1 | `try!` in LLM-triggered write paths | 🔴 Crash | 30 min |
| 2 | ToolContext is `@unchecked Sendable` with mutable vars | 🔴 Race | 2 hrs |
| 3 | `handleVision` semaphore blocks main thread | 🟠 Deadlock/freeze | 1 hr |
| 4 | `sendMessage` / `sendInternalMessage` duplication | 🟠 Bug divergence | 1 hr |
| 5 | Raw string enums with no validation on LLM writes | 🟠 Silent corruption | 2 hrs |

---

## Part 3: Purpose, Philosophy & Direction

### The Three Pillars

**Pillar 1: Capture anything, normalize to text**

The insight: text is the universal substrate for LLM processing. Audio → transcript. Scans → OCR text. PDFs → extracted text. Once everything is text, you can apply the same analysis pipeline, search uniformly, build relationships regardless of origin, and export in any format.

**The tension:** Each format has its own failure modes (transcription loss, OCR loss, PDF extraction variance). If extraction produces garbage, the entire downstream chain is poisoned. The fix: show the extraction layer explicitly — let users review/correct raw text before AI touches it.

**Pillar 2: Process transparency — the real differentiator**

Most AI tools are black boxes (ChatGPT memory, Notion AI, Otter.ai, Apple Intelligence). Wawa Note's thesis: the process is as valuable as the result. The user should see, edit, and share every transformation.

**The "recipe" concept:** Each processing step as an inspectable artifact:
```
Recipe: "Meeting Analysis"
Input: raw transcript text
Prompt: [editable system prompt]
Schema: [editable output schema]  
Post-processing: [editable rules for task/edge creation]
Output: analysis.json + tasks + edges
```

**Projects to learn from:** Obsidian + Templater/QuickAdd, n8n/Make.com, Jupyter notebooks, dbt.

**Pillar 3: Shell as durable interface**

The thesis: `ls` has meant "list files" since 1971. These commands are in every LLM's training data. They'll still work when models are 100× more capable.

**Academic validation:**
- arXiv:2601.11672 — "Files Are All You Need" (Piskala, 2026)
- "CLIs are the New AI Interfaces" (mrkaran.dev, 2025)
- arXiv:2603.18030 — "Realizing LLM Agents as Native POSIX Processes" (2026)
- "MCP is dead. Long live the CLI" (Eric Holmes, 2025)
- Hugging Face research (arXiv:2604.00073, 2026)
- Jerry Liu (LlamaIndex, 2026): "The agent really only has access to a filesystem and ~5-10 tools"

**Where to be careful:**
1. The VFS is a metaphor, not a real filesystem — `ls -la` doesn't map to real file attributes
2. The shell is great for power users, alienating for everyone else — GUI should be the frontend
3. Natural language should compose with shell commands, not replace them

### Strategic positioning

**The risk:** Positioning ambiguity. Wawa Note can be described as a meeting recorder, note-taking app, AI chat, knowledge graph, task manager, or document scanner. Being all of these means being none of them compellingly.

**The sharp positioning:** "A workbench for turning captured evidence into explorable project memory."

**Differentiators no competitor has:**
- Provenance — every conclusion traces back to source evidence
- Process transparency — every transformation is inspectable and editable
- Shell durability — the interface won't break when AI evolves
- Graph-first — not notes with links, but a typed knowledge graph with evidence

**Concrete next steps:**
1. Build the "recipe view" — show prompt + schema + output per step
2. Make the VFS exportable as real files
3. Create a recipe marketplace (even just a GitHub repo)
4. Expose the extraction step for user review
5. Position explicitly as a workbench — "The open workbench for project memory"

---

## Part 4: Development Proposals

### Proposal 1: Recipe System — The Visible Pipeline

**Priority:** Critical — this IS the product differentiator
**Effort:** Large (2-3 weeks)
**Dependencies:** None (builds on existing PromptStore + FrameworkService)

**Objective:** Every transformation the system performs is represented as an inspectable, editable, shareable artifact called a Recipe.

**What a Recipe is:**

```json
{
  "id": "recipe/meeting-analysis",
  "name": "Meeting Analysis",
  "version": 1,
  "steps": [
    {
      "id": "extract",
      "type": "extraction",
      "engine": "auto",
      "description": "Convert raw content to text"
    },
    {
      "id": "analyze",
      "type": "llm_transform",
      "systemPrompt": "You are a meeting intelligence analyst...",
      "outputSchema": { },
      "model_hint": "reasoning"
    },
    {
      "id": "ingest",
      "type": "graph_integration",
      "rules": [
        "Create task for each action_item",
        "Create person edge for each mentioned_people entry",
        "Create 'supports' edge when finding confirms existing task"
      ]
    }
  ]
}
```

**Implementation phases:**
1. Recipe model + persistence (3 days) — Codable struct, file-backed JSON, migrate PipelineTemplate into first built-in recipe, versioning with fork support
2. Recipe-aware pipeline (4 days) — ContentPipelineService reads recipe, each iteration logged against step IDs, structured events emitted, execution trace stored
3. Recipe UI (5 days) — RecipeEditorView (step cards), RecipeTraceView (input → prompt → output per step), pre/post-processing badges
4. Import/Export/Share (2 days) — Export as `.wawarecipe.json`, import from Files.app/Share Extension/URL, built-in recipes fork-only

**Design principle (from MacPaw's Composable Pipelines, May 2026):** "Developers express intent in a DSL... the runtime handles scheduling and model routing. The developer-facing surface stays stable while the execution layer improves." Use model hints (`.reasoning`, `.fastResponse`) instead of hardcoded model IDs.

### Proposal 2: Portable Project Export — Files as Truth

**Priority:** High — enables data ownership promise
**Effort:** Medium (1 week)
**Dependencies:** Proposal 1 (recipes should be included in export)

**Export format:**

```
my-project/
├── project.json                    # Project metadata, health, settings
├── README.md                       # Auto-generated project summary
├── items/
│   ├── 2026-06-01-meeting.md       # Human-readable with YAML frontmatter
│   ├── 2026-06-01-meeting.transcript.md
│   └── 2026-06-03-scan.md
├── tasks/
│   └── tasks.md                    # Markdown checklist with metadata
├── analysis/
│   └── 2026-06-01-meeting.analysis.json
├── graph/
│   ├── edges.json                  # All typed relationships
│   └── graph.md                    # Human-readable relationship summary
├── recipes/
│   └── meeting-analysis.json
└── .wawa/
    ├── item-map.json               # UUID → filename mapping (for re-import)
    └── export-metadata.json        # Export date, app version, checksums
```

**Interoperability targets:** Obsidian (open as vault), LogSeq (import markdown), Git (commit and track), Finder (browse), other Wawa Note instances (re-import with UUID preservation).

**Implementation phases:**
1. Export engine (3 days) — PortableExportService, item → markdown converter, graph → JSON + markdown
2. Import engine (3 days) — PortableImportService, handles fresh import and re-import, handles Obsidian-style markdown
3. UI integration (2 days) — Export button on project detail, import from Files.app

### Proposal 3: Extraction Review Gate — Trust Layer

**Priority:** High — builds user trust in AI outputs
**Effort:** Small (3-4 days)
**Dependencies:** None

**User flow:**

```
[Capture audio] → [Transcription completes] → [Review & Edit screen] → [Approve] → [Pipeline runs]
                                                     ↓
                                              [Edit text manually]
                                                     ↓
                                              [Approve edited version]
```

**Implementation phases:**
1. Review state in pipeline (1 day) — Add `ItemStatus.pendingReview`, pipeline pauses, "Auto-approve extraction" setting
2. Review UI (2 days) — ExtractionReviewView with editable text, confidence highlights, Approve/Re-extract/Skip buttons
3. Confidence indicators (1 day) — Apple Speech per-segment confidence, OCR character confidence, visual highlights

**Design principle:** This is the "darkroom" moment — the user sees the intermediate state and can intervene. Without this, the pipeline is a black box.

### Proposal 4: MCP Server — Open Your Knowledge to External Tools

**Priority:** Medium — high strategic value, enables ecosystem
**Effort:** Medium (1 week)
**Dependencies:** None

**MCP tools to expose:**
- `wawa_search(query, project?)` — Search items by text
- `wawa_get_item(id)` — Get full item with analysis
- `wawa_list_projects()` — List all projects with health
- `wawa_get_tasks(project, status?)` — Get tasks filtered
- `wawa_get_graph(project)` — Get typed relationships
- `wawa_get_timeline(project, days?)` — Get recent activity
- `wawa_run_recipe(item_id, recipe_id)` — Trigger analysis

**Implementation phases:**
1. Local MCP server (3 days) — MCP protocol over stdio, reads from SwiftData + FileArtifactStore
2. Network MCP server (2 days) — HTTP-based on localhost with token auth, Bonjour discovery
3. Permission model (2 days) — Per-project access control, read-only by default, audit log

**Strategic position:** Transforms Wawa Note from "an app where my knowledge lives" to "the knowledge layer that powers all my AI tools."

### Proposal 5: Shell Refinements — Prepare for Smarter Models

**Priority:** Medium
**Effort:** Small-Medium (1 week)
**Dependencies:** None

**Additions in priority order:**

| # | Feature | Effort | Description |
|---|---|---|---|
| 5.1 | Pipe support | 2 days | `command | command` chaining where output of one becomes input of next |
| 5.2 | `man` command | 1 day | Detailed per-command documentation the agent can self-discover |
| 5.3 | Session history | 1 day | `history --session`, `!!`, `!grep` — helps agents avoid repeating failed commands |
| 5.4 | Structured error suggestions | 1 day | Instead of "command not found", suggest alternatives with examples |
| 5.5 | `recipe` command | 2 days | `recipe list/show/apply/edit/fork` — native shell access to recipe system |

### Proposal 6: Capture Depth — Excel at 2-3 formats

**Priority:** Medium
**Effort:** Medium (1-2 weeks)
**Dependencies:** Proposal 3 (review gate)

**Prioritize:** Audio (primary) → Document scan (secondary) → Markdown notes (tertiary)

**Audio depth improvements:**
- Speaker diarization (3 days) — detect speaker changes, label as Speaker 1/2/3
- Tappable transcript (2 days) — tap segment to seek audio, long-press to edit
- Timestamp segments — expose in transcript view
- Language detection — auto-detect, allow manual override

**Document scan depth improvements:**
- OCR confidence — per-line confidence display
- Layout detection — tables, headers, lists
- Handwriting flagging
- Re-scan prompt for low-confidence pages
- Layout-aware OCR (2 days) — spatial grouping, markdown tables for grid patterns

### Proposal 7: Workbench Positioning — UI that shows the process

**Priority:** Medium-High
**Effort:** Small (3-4 days)
**Dependencies:** Proposal 1 (recipe system)

**Specific UI changes:**

1. **Item detail — show recipe badge** (1 day): Every analyzed item shows which recipe was used with View trace / Re-analyze / Change actions
2. **Pipeline progress — show steps not spinner** (1 day): Replace generic "Analyzing..." with per-step progress, each tappable for details
3. **Settings — "Your Recipes" section** (1 day): List built-in + custom recipes with View/Fork/Edit/Export/Delete actions
4. **Project settings — recipe assignment** (1 day): Default recipe per project, auto-analyze toggle, review requirement toggle

### Execution Order

| # | Proposal | Effort | Rationale |
|---|---|---|---|
| 3 | Extraction Review Gate | 3-4 days | Quick win. Builds trust immediately. No dependencies. |
| 1 | Recipe System | 2-3 weeks | Core differentiator. Everything else builds on this. |
| 7 | Workbench UI | 3-4 days | Makes recipes visible. Fast follow to Proposal 1. |
| 2 | Portable Export | 1 week | Delivers data ownership promise. Needs recipes. |
| 5 | Shell Refinements | 1 week | Strengthens agent interface. Independent work. |
| 6 | Capture Depth | 1-2 weeks | Polish primary formats. Parallel with 4/5. |
| 4 | MCP Server | 1 week | Strategic. Lower urgency for personal project. |

**Total estimated effort:** 6-8 weeks of focused development.

### What NOT to build (scope discipline)

| Feature | Reason to skip |
|---|---|
| Watch Connectivity | Doesn't reinforce capture/process/transparency |
| Live Activities | Nice UX polish but not core |
| MotionActivity sensor | No user value for knowledge capture |
| JSSandbox/WawaJSBridge | No evidence of use, security risk |
| On-device LLM (ModelDownloadService) | Wait for Apple Foundation Models |
| 8 built-in frameworks | Ship 3, add others when users need them |
| SkillTemplate / sub-agents | Not wired, speculative |
| OntologyInertiaService | Imperceptible effect |
| VersioningService.restore() | Dangerous without tests |

**Rule:** If a feature doesn't directly serve Capture → Process (transparent) → Knowledge (with provenance), it's out of scope for the next 2 months.

### Reference: Prior art and inspiration

| Source | What to take |
|---|---|
| MacPaw Composable Pipelines (2026) | "Model hints not model IDs." Pipeline as declarative DSL. |
| arXiv:2601.11672 — "Files Are All You Need" | Academic validation of VFS approach |
| Obsidian | Files as truth. Markdown + frontmatter. Vault = folder. |
| dbt | Every transformation is a file. Lineage is visible. |
| n8n | Visual pipeline editor. Each node inspectable. |
| Odysseus (2026) | Local-first AI workspace competitor (chat-focused, not graph-focused) |
| myKG (2026) | Confidence-scored knowledge graph from documents |

---

*This document is a self-review. The underlying bet — that meeting evidence can become explorable project memory with AI — is a good bet. Validation requires daily use on real meetings for real projects.*
