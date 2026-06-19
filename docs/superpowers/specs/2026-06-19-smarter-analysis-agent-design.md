# Smarter Analysis Agent — Design Spec

**Date:** 2026-06-19
**Status:** Approved
**Context:** The analysis agent (AgentLoop running in autonomous mode via ContentPipelineService) struggles with its operational boundaries. It attempts commands it shouldn't, accesses items outside its sandbox, repeats failing commands, and hits the circuit breaker. The root cause: poor contextualization and cryptic error feedback.

## Problem Summary

The agent receives a generic system prompt (`PipelineTemplate.standard`) and low-level shell errors (`"cat: missing path"`, `"command not found"`, `"Access denied"`). Without understanding its exact file structure, valid commands, and sandbox boundaries, it wastes iterations exploring invalid paths and retrying doomed commands until the circuit breaker kills the loop.

### Concrete failure modes observed

1. **Sandbox violations** — agent tries to `cd` to other items or `/projects/`
2. **Wrong commands** — agent uses `ls`, `find`, `grep`, `echo` during analysis when only `cat`, `write_analysis`, `set_title`, `resolve_speakers` apply
3. **Repeated errors → circuit breaker** — same command tried 2-3 times with minor variations, all fail, then 5 consecutive errors terminate the loop

## Solution: Context Map + Smart Feedback (Approach 1)

Two complementary layers that bookend the agent's execution:

1. **AnalysisContextMap** — a rich dynamic preamble injected into the system prompt BEFORE the agent starts, giving it a precise map of its workspace, valid commands, forbidden commands, and guardrails.
2. **AnalysisFeedbackProvider** — a middleware that intercepts tool errors AFTER execution and rewrites them with semantic context: what went wrong, why, and what to try instead.

## Section 1 — AnalysisContextMap (Preamble)

### What it is

A markdown block generated dynamically by `ContentPipelineService` before launching the agent. It replaces the generic opening of `PipelineTemplate.standard`.

### Structure

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CONTEXT MAP — Item Analysis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📁 YOUR WORKSPACE: /inbox/"Weekly Sync — 2026-06-19"/

Files available to you:
  body.md           — raw note text (1.2 KB)
  transcript.json   — full meeting transcript (24 KB, 8 speakers)
  audio.m4a         — original recording (14.2 MB)
  metadata.json     — item metadata (read-only)

🚫 SANDBOX: You can ONLY read/write files under this directory.
   Do NOT try to cd to /inbox/other-item/ or /projects/.
   Do NOT try to access other items.

📋 REQUIRED WORKFLOW (4 steps):
   Step 1 — EXTRACT: cat body.md (or transcript.json if audio item)
   Step 2 — TITLE:   set_title based on content
   Step 3 — ANALYZE: write_analysis with sections: summary (required),
             key_points, decisions, action_items, risks, people
   Step 4 — SPEAKERS: resolve_speakers (if transcript has speakers)

⚡ VALID COMMANDS HERE:
   cat <file>          — read body.md or transcript.json
   set_title <title>   — rename the item
   select_schema <name>— pick analysis schema
   select_skill <name> — pick analysis skill
   write_analysis      — save structured analysis
   resolve_speakers    — match speakers to contacts
   ask_user <question> — ask user for clarification
   help                — show all commands

🛑 DO NOT:
   - Try to ls, cd, find, grep, echo, rm, mv, touch, export, recipe
   - Try to access /projects/, /exports/, or other items
   - Use write_analysis without first reading content
   - Retry the same failing command more than twice
   - Loop without making progress

📐 APPLICABLE SCHEMA: meeting (decisions_actions also available)
   Required sections: summary, key_points, decisions, action_items
   Optional sections: risks, people, timeline
```

### Dynamic generation

`AnalysisContextMap.build(for:in:vfsState:)`:

1. **VFS pre-read** — calls `VFSService.listChildren(item)` to know exactly which files exist
2. **Framework/schema resolution** — if the project has a framework, lists required sections
3. **Command filtering** — based on content type (transcript vs note vs document) and sandbox mode
4. **Negative rules** — the inverse: commands that are globally available but NOT valid in analysis mode
5. **Assembly** — formats the block in ~300-500 tokens

### Integration point

In `ContentPipelineService.process()`, phase 3, before creating the `AgentLoop`:

```swift
let contextMap = AnalysisContextMap.build(for: item, in: project, vfsState: vfsState)
let systemPrompt = contextMap.preamble + "\n\n" + template.body
```

## Section 2 — AnalysisFeedbackProvider (Smart Errors)

### What it is

A middleware layer between `ShellInterpreter`/tool execution and the `AgentLoop`'s result stream. When a tool returns `isError: true`, the provider enriches the error message with semantic context before the LLM sees it.

### AnalysisFeedbackProvider

A class (not a protocol) to avoid Swift existential mutability issues with optional chaining. Testability comes from injecting a pre-built `FeedbackContext`, not from protocol conformance.

```swift
final class AnalysisFeedbackProvider {
    let context: FeedbackContext
    private var attemptHistory: [String] = []

    init(context: FeedbackContext) { self.context = context }

    func enrich(error: ToolResult) -> ToolResult
    func record(attempt: String)
}
```

### FeedbackContext

```swift
struct FeedbackContext {
    let itemPath: String           // "/inbox/Weekly Sync/"
    let availableFiles: [String]   // filenames relative to item directory: ["body.md", "transcript.json"]
    let validCommands: [String]    // ["cat", "set_title", "write_analysis", ...]
    let forbiddenCommands: [String] // ["ls", "cd", "find", "grep", ...]
    let activeSchema: String?      // "meeting"
}

// Internal to AnalysisFeedbackProvider:
// attemptHistory: [String] — last 10 attempted commands (for repetition detection)
```

### Enrichment rules

| Error pattern | Current response | Enriched response |
|---|---|---|
| `cat: missing path` | `"cat: missing path. Usage: cat <path>"` | `"cat precisa de um caminho. Arquivos disponíveis: body.md, transcript.json. Exemplo: cat body.md"` |
| Command not found | `"unknown: command not found. Did you mean: ls, cd, cat?"` | `"'X' não é um comando válido neste contexto de análise. Comandos disponíveis: cat, set_title, write_analysis, resolve_speakers, ask_user, help."` |
| Sandbox violation | `"Access denied: item X is outside the current analysis scope"` | `"Acesso negado. Você está analisando '/inbox/Weekly Sync/' e não pode acessar outros itens. Use apenas os arquivos em: body.md, transcript.json."` |
| echo misuse | `"echo: body must be valid JSON..."` | `"JSON inválido. Se você quer salvar análise, use write_analysis — não echo. Se precisar de echo mesmo, o corpo precisa ser JSON válido."` |
| Schema validation fail | (existing field errors) | Keeps field errors + adds: `"Dica: revise as seções required: [summary, key_points, decisions, action_items]."` |
| Repetition detected | (doesn't exist today) | `"⚠️ Você tentou 'X' duas vezes e falhou nas duas. Sugestão: tente uma abordagem diferente. Próximo passo sugerido: cat body.md para ler o conteúdo."` |
| Circuit breaker (5th error) | `"Agent stopped after 5 consecutive failed tool calls"` | `"❌ 5 erros consecutivos. Resumo: [breakdown]. Última chance: use cat body.md e write_analysis."` |

### Rule composition

Each rule is a pure function:

```swift
typealias FeedbackRule = (ToolResult, FeedbackContext) -> ToolResult?

let rules: [FeedbackRule] = [
    enrichMissingPath,
    enrichCommandNotFound,
    enrichSandboxViolation,
    enrichEchoMisuse,
    enrichSchemaFailure,
    detectRepetition,
    enrichCircuitBreaker
]
```

Rules are tried in order. First match wins. If no rule matches, the original error passes through unchanged.

### Integration point

In `AgentLoop.runAutonomous()`, after tool execution and before appending to `toolResults`:

```swift
var result = try await tool.execute(arguments, context: toolContext)
if result.isError {
    result = feedbackProvider?.enrich(error: result) ?? result
}
toolResults.append(result)
feedbackProvider?.record(attempt: "\(tool.name) \(argsSummary)")
```

## Section 3 — Implementation Plan

### New files

| File | Purpose |
|---|---|
| `Domain/Agent/AnalysisContextMap.swift` | Generates the contextual preamble + FeedbackContext |
| `Domain/Agent/AnalysisFeedbackProvider.swift` | Enriches tool errors with semantic context |

### Modified files

| File | Change | Scope |
|---|---|---|
| `Domain/Services/ContentPipelineService.swift` | Integrate ContextMap + FeedbackProvider in phase 3 | Medium |
| `Domain/Agent/AgentLoop.swift` | Accept optional `feedbackProvider` param; enrich errors; record attempts; enriched circuit breaker summary | Small |

### Unchanged files

- `ShellTool.swift` / `ShellInterpreter.swift` — zero changes, continue returning raw errors
- `WriteAnalysisTool.swift` — zero changes, schema validation unchanged
- `PipelineTemplate` — zero changes, preamble is prepended not replaced
- `AgentTool` protocol, `ToolContext`, `VFSService` — zero changes

### Data flow

```
ContentPipelineService.process()
  │
  ├─ 1. VFSService.listChildren(item) → VFS state
  │     └─ AnalysisContextMap.build(item, project, vfsState)
  │           │
  │           ├─ preamble → injected into system prompt
  │           └─ FeedbackContext → passed to AgentLoop
  │
  ├─ 2. AgentLoop.runAutonomous(
  │       systemPrompt: contextMap.preamble + template.body,
  │       feedbackProvider: AnalysisFeedbackProvider(context: feedbackContext)
  │     )
  │
  └─ 3. Inside AgentLoop, for each toolResult:
        if result.isError:
          enriched = feedbackProvider.enrich(error: result)
          → LLM receives enriched error instead of raw error
```

### Circuit breaker replacement

Current behavior: after 5 consecutive errors, throw `AgentLoopError.circuitBreaker` with a generic message.

New behavior: before throwing, the feedback provider builds an enriched summary of all 5 errors, categorized by type (sandbox ×2, unknown command ×2, JSON invalid ×1), with a final suggestion. This is appended as the last tool result so the LLM receives context even on termination.

## Section 4 — Tests

All tests in `CoreServicesTests.swift`:

| Test | What it verifies |
|---|---|
| `testContextMap_generatesPreambleForAudioItem` | Audio items get transcript.json + audio.m4a in file list, correct commands |
| `testContextMap_generatesPreambleForNoteItem` | Note items get body.md, no transcript commands |
| `testFeedback_enrichMissingPath` | `cat: missing path` → enriched with available files |
| `testFeedback_enrichCommandNotFound` | `unknown` → enriched with valid command list |
| `testFeedback_enrichSandboxViolation` | Access denied → enriched with current item path |
| `testFeedback_detectsRepetition` | Same command 2x → repetition warning injected |
| `testFeedback_circuitBreakerSummary` | 5 errors → summary built with correct categorization |
| `testContextMap_forbiddenCommandsNeverInValidList` | Invariant: no command appears in both lists |
| `testFeedback_unknownErrorPassesThrough` | Errors without a matching rule pass through unchanged |

## Section 5 — Design Decisions

1. **Preamble is additive, not replacement** — `PipelineTemplate.standard` stays as fallback. The preamble is prepended. If preamble generation fails, the system degrades gracefully to the existing prompt.
2. **FeedbackProvider is an optional class instance in AgentLoop** — `AgentLoop.runAutonomous()` accepts `feedbackProvider: AnalysisFeedbackProvider? = nil`. When nil (chat mode, project agent), behavior is unchanged. Only the analysis pipeline injects it. The class (not protocol) design avoids Swift existential mutability issues with optional chaining.
3. **Rules are pure functions, not a class hierarchy** — a flat array of `FeedbackRule` closures. Adding a new error pattern is one function + one array append. No subclassing, no visitor pattern.
4. **Error messages are in Portuguese** — matching the app's primary language. The code identifiers and schemas stay in English.
5. **No changes to ShellInterpreter** — the raw errors are preserved. The enrichment is a separate concern. This keeps the VFS shell reusable for chat mode where contextual errors would be noise.
