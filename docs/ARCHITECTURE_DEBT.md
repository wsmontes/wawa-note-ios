# Architecture Debt — Sprint 3 Roadmap

> Created: 2026-07-13 (Sprint 3)
> Status: Living document — update as splits are completed.

This document captures the planned incremental decompositions of god objects
and the dependency injection migration path. Each item is designed to be done
independently without blocking other work.

---

## 1. ContentPipelineService.swift (~155 KB, ~950 lines)

**Current state:** Single class handling pipeline orchestration, template
resolution, agent execution, status reporting, and direct item processing.

**Split plan:**

| New File | Responsibility | Key Methods to Extract |
|----------|---------------|----------------------|
| `PipelineOrchestrator.swift` | Job lifecycle: start, cancel, retry, concurrency | `process(_:using:)`, `cancelItem(_:)`, `activeJobs` management |
| `PipelineTemplateStore.swift` | Template/lens resolution and caching | `resolveTemplate(for:)`, `LensCatalogService` (already inline) |
| `PipelineAgentRunner.swift` | LLM agent execution and streaming | Agent invocation, prompt assembly, streaming response handling |
| `PipelineStatusReporter.swift` | Notification posting, stage tracking, progress | `.pipelineCompleted`, `.contentPipelineStageChanged` posts |

**Migration strategy:**
1. Extract `LensCatalogService` to its own file (already a separate class, just co-located)
2. Extract `PipelineStatusReporter` — pure side-effect-free notification logic
3. Extract `PipelineTemplateStore` — stateless resolution
4. Extract `PipelineAgentRunner` — async agent calls
5. `ContentPipelineService` becomes a thin `PipelineOrchestrator` facade

**Risk:** High coupling between orchestration and status. Extract reporter first
to establish the notification boundary.

---

## 2. ChatView.swift — Extract DictationService

**Current state:** `ChatView` contains inline dictation/speech-recognition logic
mixed with UI state.

**Split plan:**
- Create `DictationService.swift` (ObservableObject)
- Move `SFSpeechRecognizer` setup, audio session config, real-time transcription
- ChatView keeps a `@StateObject var dictation: DictationService`
- DictationService exposes: `isListening`, `transcript`, `start()`, `stop()`

**Benefit:** Reusable across any view that needs voice input; testable in isolation.

---

## 3. RecordingCoordinator.swift — Extract ManifestManager & RecoveryService

**Current state:** RecordingCoordinator manages recording lifecycle, crash
recovery, manifest persistence, and orphaned file cleanup in one class.

**Split plan:**

| New File | Responsibility |
|----------|---------------|
| `ManifestManager.swift` | Read/write/validate recording manifests on disk |
| `RecoveryService.swift` | `cleanupOrphanedRecordings()`, crash detection, partial file salvage |

**Migration strategy:**
1. Extract `ManifestManager` first — pure file I/O, no async dependencies
2. Extract `RecoveryService` — depends on ManifestManager + ModelContext
3. RecordingCoordinator delegates to both, stays focused on active recording

---

## 4. ShellInterpreter.swift — ShellCommand Protocol

**Current state:** Large switch/if-else tree dispatching shell commands inline.

**Split plan:**
- Define `protocol ShellCommand { var name: String; func execute(...) async throws -> String }`
- One conforming struct per command (e.g., `LsCommand`, `CatCommand`, `GrepCommand`)
- `ShellInterpreter` becomes a registry: `[String: ShellCommand]`
- New commands are added by creating a file + registering, no interpreter changes

**Benefit:** Open/closed principle; each command testable in isolation.

---

## 5. HomeView.swift — Extract HomeViewModel

**Current state:** `HomeView` contains data fetching, filtering logic, and
computed properties inline.

**Split plan:**
- Create `HomeViewModel.swift` (ObservableObject)
- Move: fetch descriptors, filter/sort logic, computed counts, search state
- HomeView becomes a pure rendering layer

**Benefit:** Xcode previews become instant (no data layer); unit-testable logic.

---

## 6. ProjectModels.swift — One File Per Model

**Current state:** Multiple SwiftData `@Model` classes in a single file.

**Split plan:**
- `Project.swift`, `TaskItem.swift`, `Person.swift`, `GraphEdge.swift`,
  `Entity.swift`, `AgentSuggestion.swift`, `ProjectFrame.swift`,
  `ChangeRecord.swift`, `ProjectSnapshot.swift`, `ProjectDerivedItem.swift`
- Each file contains one `@Model` class + its extensions

**Migration:** Mechanical move. No logic changes. Do in one commit.

---

## 7. AIConfigService — Dependency Injection Migration

**Current state:** `AIConfigService.shared` singleton accessed from 77+ call sites.
Not testable — tests cannot inject mock configurations.

**Migration plan:**

### Phase 1: Define Protocol (this sprint)
```swift
protocol AIConfigServiceProtocol {
    var config: AIConfig { get }
    func config(for projectSlug: String?) -> AIConfig
}

extension AIConfigService: AIConfigServiceProtocol {}
```

### Phase 2: Accept Protocol in New Code
All new services accept `any AIConfigServiceProtocol` in their init.
Existing code continues using `.shared` unchanged.

### Phase 3: Gradual Migration (future sprints)
Convert high-value call sites (services under test) to accept the protocol.
Priority order:
1. `ContentPipelineService` — most complex consumer
2. `ProviderRoutingService` — provider selection logic
3. `AutomationSettings` — automation config validation
4. View models — last, lowest value for unit tests

### Phase 4: Environment Injection
Add `AIConfigServiceProtocol` to SwiftUI environment for views.
Remove `.shared` access pattern entirely.

**Note:** Do NOT change all 77 sites at once. Each service migration is a
separate PR with its own tests.

---

## Priority Order

| # | Item | Effort | Impact | Risk |
|---|------|--------|--------|------|
| 1 | ProjectModels split | XS | Medium | None |
| 2 | LensCatalogService to own file | XS | Low | None |
| 3 | AIConfigService protocol (Phase 1) | S | High | None |
| 4 | HomeViewModel extraction | S | Medium | Low |
| 5 | DictationService extraction | M | Medium | Low |
| 6 | ManifestManager extraction | M | Medium | Low |
| 7 | ShellCommand protocol | M | High | Low |
| 8 | PipelineStatusReporter | M | High | Medium |
| 9 | Full ContentPipelineService split | XL | Very High | Medium |

---

## Completed Items

- [x] **Item 12** — Guard + assertionFailure for temporal coupling in ProcessingQueueService (2026-07-13)
- [x] **Item 13** — Robust polling fallback in processEntry timeout (2026-07-13)


---

## 8. @unchecked Sendable Audit

**Current state:** Multiple types in the codebase are marked `@unchecked Sendable`
to silence strict concurrency warnings without actually proving thread safety.
This suppresses compiler diagnostics that exist to prevent data races.

**Known instances (non-exhaustive):**
- Model wrapper types passed between actors
- Closure-capturing classes sent across isolation boundaries
- Service objects shared between MainActor and background Tasks

**Risk:** Each `@unchecked Sendable` conformance is a promise to the compiler
that the type is safe to share across concurrency domains. If that promise is
wrong, data races occur silently — no compiler warning, no runtime assertion
(outside of TSan). These are the hardest bugs to diagnose.

**Remediation strategy (future sprint):**
1. **Audit pass:** `grep -r "@unchecked Sendable"` across the project. Categorize each hit:
   - **Safe:** Immutable value types, types protected by locks/actors → document why safe
   - **Unsafe:** Mutable classes, types with unsynchronized state → remove `@unchecked`, fix errors
   - **Needs refactor:** Types that should be actors or use `sending` parameter
2. **Priority order:** Fix types that cross actor boundaries during recording/transcription
   first (highest data-race risk). UI-only types are lower priority.
3. **Testing:** Enable Thread Sanitizer (TSan) in the test scheme to catch races that
   `@unchecked Sendable` hides. Add a CI job that runs with TSan enabled.
4. **Prevention:** Add a SwiftLint custom rule or PR review checklist item:
   "Every new `@unchecked Sendable` must include a `// SAFETY:` comment explaining
   why the type is actually safe to share."

**Note:** This is NOT a single-PR fix. Each type needs individual analysis.
Bulk-removing `@unchecked Sendable` will produce hundreds of compiler errors
that require structural changes (adding `@MainActor`, converting to actor,
making properties `let`, adding locks, etc.).

---

## Completed Items

- [x] **Item 17** — Race condition in RecordingCoordinator manifest closures: wrapped in `Task { @MainActor in }` (2026-07-13)
- [x] **Item 18** — @unchecked Sendable audit documented (2026-07-13)
- [x] **Item 19** — cleanupOrphanedRecordings unbounded Tasks: sequential processing (2026-07-13)
- [x] **Item 20** — Checkpoint saver concurrent writes: nil out onCheckpoint before final write (2026-07-13)