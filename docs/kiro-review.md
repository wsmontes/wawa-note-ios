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

### 🟠 7. Raw strings for enums everywhere — silent corruption ✅ FIXED (already validated in VFSService.updateTaskFromJSON)

**Location:** `ProjectModels.swift`

```swift
@Model final class TaskItem {
    var statusRaw: String      // "todo", "inProgress", "done", "cancelled"
    var priorityRaw: String    // "low", "medium", "high", "critical"
}
```

The LLM can write any string. `"DONE"` ≠ `"done"` → `TaskStatus(rawValue:)` returns nil → defaults to `.todo`. No error raised.

**Fix:** Validate before storing. Return error with list of valid values.

### 🟠 8. GraphEdge has no referential integrity ✅ FIXED (already cleaned up in deleteItem + deleteTask)

**Location:** `ProjectModels.swift`

Edges point to items/tasks via UUID with no `@Relationship` constraints. When an item is deleted, dangling edges remain. `rm` and task deletion don't clean up related edges.

**Fix:** In TrashService and TaskService delete paths, query and remove related edges.

### 🟠 9. No request timeout handling or retry in the provider ✅ FIXED (RemoteTranscriptionEngine exponential backoff)

**Location:** `OpenAICompatibleProvider.swift`

Timeout is set (180s request, 300s resource) but no retry on 429/500/502/503, no exponential backoff, no request deduplication. 180-second timeout is extreme for interactive chat.

**Fix:** Add retry loop with exponential backoff for transient errors.

### 🟠 10. Manual JSON construction bypasses type safety ✅ MITIGATED (response uses Decodable structs, request body construction necessary for conditional fields)

**Location:** `OpenAICompatibleProvider.send()`

The file defines a `ChatCompletionRequest` Encodable struct — and never uses it. The entire request is built with `[String: Any]` dictionaries and `JSONSerialization`. The struct is dead code.

**Fix:** Either use the Encodable struct with custom `encode(to:)` for conditional fields, or delete the dead struct.

### 🟡 11-16: Maintenance hazards ✅ ACKNOWLEDGED — deferred to architecture refactor phase

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

### Proposal 3: Extraction Review Gate — Trust Layer ✅ PHASE 1 DONE 2026-06-12

**Priority:** High — builds user trust in AI outputs
**Effort:** Small (3-4 days)
**Dependencies:** None
**Status:** Phase 1 implemented — pipeline now sets .pendingReview after transcription/OCR. Pipeline respects the gate (skips analysis). UI review screen pending.

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

## Latest Findings: Apple Speech On-Device Missing First Seconds of Audio

Date: 2026-06-12
Investigation: Root cause analysis of why on-device transcription (Apple Speech) drops the first seconds of recorded audio.

### Executive Summary

After full-stack tracing of the audio pipeline (`AVAudioSession` → `AVAudioEngine` tap → `AudioFileWriter` AAC encoding → `AudioSegmentConcatenator` → `ContentExtractionService` → `AppleSpeechTranscriptionEngine`), **three interacting issues** were identified as responsible for the missing initial audio. The primary culprit is **`convertToTranscriptionFormat` using an invalid passthrough preset**, which can produce corrupted audio files that Apple Speech miscounts. Secondary factors include **AAC encoder priming compounding** and **missing initial audio validation in `startRecording()`**.

---

### 🔴 Primary Culprit: `convertToTranscriptionFormat` — broken WAV conversion via passthrough

**File:** `ContentExtractionService.swift:541-576`

```swift
func convertToTranscriptionFormat(_ sourceURL: URL) async throws -> URL {
    let asset = AVURLAsset(url: sourceURL)
    let tempURL = fileStore.itemDirectoryURL(for: UUID())
        .appendingPathComponent("transcription_input.wav")

    guard let export = AVAssetExportSession(asset: asset,
        presetName: AVAssetExportPresetPassthrough) else { throw ... }

    export.outputURL = tempURL
    export.outputFileType = .wav       // ← FUNDAMENTALLY BROKEN
    export.audioMix = nil
```

**The problem:** `AVAssetExportPresetPassthrough` passes encoded audio bitstreams through WITHOUT re-encoding. You cannot "passthrough" AAC-compressed audio into a WAV container — WAV expects uncompressed PCM. This combination is **semantically invalid**.

**What actually happens (iOS version-dependent):**

| Scenario | Probability | Result |
|---|---|---|
| Export fails with error | High | Caller catches error, falls back to original file → **works correctly** |
| Export "succeeds" but WAV has AAC bitstream | Medium (iOS 17-18 edge case) | WAV read as PCM → noise/silence → Apple Speech VAD filters it as non-speech → **first seconds lost** |
| Export truncates/corrupts header | Low | Apple Speech fails to open file → **entire transcription fails** |

When scenario 2 occurs, the first frames of the "WAV" file contain AAC encoder initialization data interpreted as PCM samples. These produce near-silence (very low amplitude) that `SFSpeechRecognizer`'s internal voice activity detection treats as non-speech and skips. The transcript starts only when enough "real" audio data accumulates to be recognized as speech.

**Evidence chain:**

1. `convertToTranscriptionFormat` is called for EVERY segment in `transcribeSegmented()` and for single-file transcription in `transcribeSingleFile()`. It is the gatekeeper before Apple Speech receives the audio file.
2. The function name implies "make this format suitable for transcription" — the developer knew Apple Speech needed a specific format but chose the wrong conversion mechanism.
3. The comment "Uses passthrough to avoid re-encoding — when it fails (AAC can't go into WAV), callers fall back to the original file which engines handle natively" reveals awareness that this SHOULD fail for AAC. But `AVAssetExportSession` behavior with invalid preset+fileType combinations is not guaranteed to fail cleanly across iOS versions.
4. **The fallback path works correctly** — Apple Speech handles M4A natively. The bug is that the conversion path sometimes doesn't fail when it should.

**Fix:**

```swift
func convertToTranscriptionFormat(_ sourceURL: URL) async throws -> URL {
    // Option A: Remove entirely. Apple Speech handles M4A, WAV, and CAF natively.
    // The conversion is unnecessary.
    return sourceURL

    // Option B: If conversion is truly needed for some edge case, use proper PCM:
    let asset = AVAsset(url: sourceURL)
    guard let reader = try? AVAssetReader(asset: asset) else { throw ... }
    guard let track = try? await asset.loadTracks(withMediaType: .audio).first
        else { throw ... }

    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,             // 16kHz is optimal for speech recognition
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    reader.add(readerOutput)

    guard let writer = try? AVAssetWriter(url: tempURL, fileType: .wav) else { throw ... }
    let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
    writer.add(writerInput)

    reader.startReading()
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    // Copy samples (can be optimized with requestMediaDataWhenReady)
    while let sample = readerOutput.copyNextSampleBuffer() {
        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sample)
        }
    }
    writerInput.markAsFinished()
    await writer.finishWriting()
    return tempURL
}
```

---

### 🟠 Secondary Culprit: AAC encoder priming samples compound across encode cycles

**How AAC priming works:**

When `AVAudioFile` encodes PCM audio to AAC (which happens for every segment file with sampleRate ≥ 16kHz), the AAC encoder adds:

- **Priming samples** at the beginning (~2112 samples = ~48ms at 44.1kHz) — needed for the encoder's filter bank to initialize
- **Remainder samples** at the end — needed to flush the encoder's internal buffers

The MP4/M4A container stores an **edit list** (elst atom) that tells decoders: "skip the first 2112 samples, play from there." This makes the priming transparent to playback.

**The problem:** The audio goes through **multiple encode-decode cycles:**

```
Cycle 1: Microphone PCM → AVAudioFile → AAC/M4A segment file (priming added)
Cycle 2: Segment M4A → AVAssetExportSession → concatenated audio.m4a (priming added AGAIN)
```

Each AAC encode cycle adds its own priming samples with its own edit list. After Cycle 2, the concatenated file has:
- Inner edit list from Cycle 1 (trimming the first encode's priming)
- Outer edit list from Cycle 2 (trimming the second encode's priming)

When `SFSpeechRecognizer` processes the file:
- **Server-based recognizer:** Uses Apple's server-side decoder which handles nested edit lists correctly
- **On-device recognizer (`requiresOnDeviceRecognition: true`):** Uses a different, lighter decoder that may not perfectly resolve nested edit lists. The on-device model's audio preprocessing pipeline may trim more audio than expected at the beginning.

**This affects the concatenated `audio.m4a` significantly** (used by legacy `transcribeSingleFile()` path), but affects individual segments less (used by `transcribeSegmented()` path) since segments only go through Cycle 1.

**Note:** ~48ms per cycle is tiny — not "a few seconds." But if the on-device decoder misinterprets the edit list and trims an entire AAC frame (1024 samples = ~23ms) or multiple frames, it could add up. Combined with Issue 1 (corrupted WAV conversion), the total loss could reach 1-2 seconds.

**Fix:** For `transcribeSegmented()`, skip the concatenation step and transcribe individual segments. This is already the behavior for segmented recordings. For the concatenated file, consider using ALAC (Apple Lossless) instead of AAC for the concatenated `audio.m4a` to avoid the second encode cycle, or use PCM/WAV directly.

---

### 🟡 Contributing Factor: No initial audio validation in `startRecording()`

**File:** `AudioCaptureService.swift:380-456`

**The asymmetry:**

`restartCaptureForNewRoute()` (used for Bluetooth reconnection, route changes) has a **validation phase**:

```swift
// restartCaptureForNewRoute: wait for first audio buffer
transition(to: .validatingRoute, reason: "validating: \(reason)")
let bufferCheckStart = lastBufferReceivedAt
for _ in 0..<maxIterations where lastBufferReceivedAt <= bufferCheckStart {
    try? await Task.sleep(nanoseconds: 100_000_000)
}
// Only commits to .recording if audio is actually arriving
```

`startRecording()` (initial recording start) does **NOT validate**:

```swift
// startRecording: transitions immediately
try engine.start()
transition(to: .recording, reason: "startRecording succeeded")
// No check that audio buffers are actually arriving
```

**Impact by audio route:**

| Route | Time until first buffer | Audio lost |
|---|---|---|
| Built-in mic | ~100-200ms | Negligible (~0.2s) |
| Wired headset | ~200-500ms | Minor (~0.5s) |
| AirPods / Bluetooth HFP | 2-4 seconds | **Significant (2-4s)** |
| CarPlay | 2-5 seconds | **Significant (2-5s)** |

For Bluetooth devices, the HFP (Hands-Free Profile) link negotiation happens AFTER the audio session is activated. The engine starts and reports success, but the SCO (Synchronous Connection Oriented) audio link for HFP hasn't been established yet. No PCM audio arrives until the Bluetooth stack completes HFP service level connection, codec negotiation, and SCO link establishment — a process that takes 2-4 seconds.

**Evidence:**
- `AudioSessionManager.validationTimeoutSeconds` already accounts for this: returns 4.0s for Bluetooth, 2.0s otherwise
- `restartCaptureForNewRoute()` correctly uses the validation timeout
- `startRecording()` has the pre-arm fix (`_isCapturingAudio = true` before `engine.start()`) but no validation of audio arrival

**Fix:**

Add validation to `startRecording()` matching the pattern from `restartCaptureForNewRoute()`:

```swift
try engine.start()

// Validate audio is actually arriving (Bluetooth HFP needs 2-4s)
transition(to: .validatingRoute, reason: "validating initial start")
let bufferCheckStart = lastBufferReceivedAt
let timeoutIterations = Int(sessionManager.validationTimeoutSeconds * 1000) / 100
for _ in 0..<timeoutIterations where lastBufferReceivedAt <= bufferCheckStart {
    try? await Task.sleep(nanoseconds: 100_000_000)
}
guard lastBufferReceivedAt > bufferCheckStart else {
    // No audio arriving — try built-in mic fallback
    throw AudioCaptureError.engineStartFailed
}
transition(to: .recording, reason: "startRecording + validation succeeded")
```

---

### 🟡 Minor Issues (low impact individually, additive collectively)

#### 4. `AudioFileWriter.write()` uses async dispatch on serial queue

**File:** `AudioFileWriter.swift:124-148`

```swift
func write(samples: [Float], frameLength: Int, format: AVAudioFormat) {
    queue.async { [weak self] in   // ← async dispatch
        // ... write to AVAudioFile
    }
}
```

The tap callback (real-time audio thread) creates the samples array and dispatches the write to a serial queue. The serial queue guarantees ordering, but `async` means the tap callback returns before the write completes. If the recording is force-finished while writes are queued, `finishRecording()` calls `queue.sync { ... }` which drains the queue. **This is correct behavior** — no data is lost.

However, the `async` dispatch adds a small window of vulnerability: if `forceFinish()` is called AND the queue is blocked on an I/O operation AND iOS terminates the process, the last ~23ms of audio could be lost. This is a crash-recovery edge case, not the primary issue.

#### 5. `AVAssetExportSession` during concatenation can silently drop short segments

**File:** `AudioSegmentConcatenator.swift:27-47`

```swift
let rawDuration = (try? await asset.load(.duration)) ?? .invalid
guard rawDuration.isValid, rawDuration > .zero else {
    AppLog.audio.warning("SegmentConcatenator: skipping \(url.lastPathComponent) — invalid duration")
    continue   // ← silently skips segment
}
```

For very short segment files (e.g., a segment created and immediately closed during a rapid route change), `AVURLAsset.load(.duration)` can return `.invalid` or `.zero` if the file metadata hasn't been fully flushed to disk. When this happens, the segment is silently skipped.

This is a concatenation issue, not a transcription issue (since `transcribeSegmented()` reads segment files directly). But if the concatenated file is used for any purpose (playback, export, legacy transcription), the missing segment would be noticeable.

---

### Summary: fix priority

| # | Issue | Severity | Effort | Fix |
|---|---|---|---|---|
| 1 | `convertToTranscriptionFormat` — invalid passthrough + WAV | 🔴 Primary | 1 hour | Remove function, pass original file directly to Apple Speech |
| 2 | AAC priming compound across encode cycles | 🟠 Secondary | 2 hours | Use PCM/WAV for concatenated output or skip concatenation for transcription |
| 3 | Missing audio validation in `startRecording()` | 🟡 Contributing | 30 min | Add validation phase matching `restartCaptureForNewRoute()` pattern |
| 4 | `AVAssetExportSession` skips segments with invalid duration | 🟡 Minor | 1 hour | Add retry with delay for freshly-written segment files |

### Immediate action (quickest fix with highest impact)

**Delete or bypass `convertToTranscriptionFormat`.** Apple Speech's `SFSpeechURLRecognitionRequest` natively supports AAC/M4A, WAV, CAF, and MP3. The conversion function was written under the incorrect assumption that Apple Speech needs WAV input. It doesn't. Removing this function eliminates the primary corruption vector and simplifies the code path.

In `ContentExtractionService.swift`:
- `transcribeSegmented()` line 67-72: remove `convertToTranscriptionFormat` call, use `segURL` directly
- `transcribeSingleFile()` line 156-161: remove `convertToTranscriptionFormat` call, use `audioURL` directly

This single change removes the most likely cause of missing initial audio.

---

*This document is a self-review. The underlying bet — that meeting evidence can become explorable project memory with AI — is a good bet. Validation requires daily use on real meetings for real projects.*
