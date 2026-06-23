# Decisions — AI Meeting Companion iOS

Use this file as a lightweight Architecture Decision Record.

Claude Code should update this file when architecture or implementation direction changes.

## Format

```text
## ADR-000X — Title

Date:
Status: Proposed | Accepted | Superseded

Context:
Decision:
Consequences:
```

---

## ADR-0001 — Native iOS app with SwiftUI

Date: 2026-05-25  
Status: Accepted

Context:

The first target is an iPhone app built with Xcode and tested on iPhone 14 Plus.

Decision:

Use native iOS with Swift and SwiftUI.

Consequences:

- Good access to AVFoundation, Speech, Keychain, SwiftData, Vision, EventKit.
- Better fit for meeting recording than a web app.
- Requires Xcode/iOS-specific testing.

---

## ADR-0002 — Provider-agnostic AI architecture

Date: 2026-05-25  
Status: Accepted

Context:

The app must work with multiple AI providers and local-network providers.

Decision:

Create an `AIProvider` abstraction and keep provider-specific JSON inside provider implementations.

Consequences:

- Easier to support OpenAI, Gemini, Anthropic, LM Studio, Ollama-compatible endpoints.
- More initial architecture, less provider lock-in.
- UI and analysis code should never depend on provider-native JSON.

---

## ADR-0003 — Transcription engine abstraction

Date: 2026-05-25  
Status: Accepted

Context:

The app may use Apple Speech, SpeechAnalyzer, WhisperKit, or remote transcription.

Decision:

Create a `TranscriptionEngine` abstraction.

Consequences:

- MVP can start with Apple native transcription.
- WhisperKit can be added later without rewriting meeting workflow.
- Allows comparing engines on iPhone 14 Plus.

---

## ADR-0004 — Apple Foundation Models not MVP baseline

Date: 2026-05-25  
Status: Accepted

Context:

Target device is iPhone 14 Plus, which should not be treated as Apple Intelligence-capable.

Decision:

Do not make Apple Foundation Models a dependency of MVP 1.

Consequences:

- Heavy reasoning should use remote or local-network providers.
- Local intelligence should focus on Core ML, Natural Language, Vision, Sound Analysis, and WhisperKit experiments.
- Add Apple Foundation Models later as optional provider on supported devices.

---

## ADR-0005 — Hybrid storage model

Date: 2026-05-25  
Status: Accepted

Context:

Meeting data includes metadata, audio files, transcript JSON, analysis JSON, provider configs, and secrets.

Decision:

Use:

```text
SwiftData for metadata
FileManager for large artifacts
Keychain for secrets
```

Consequences:

- Audio files do not bloat the database.
- API keys remain secure.
- Export/import is easier.
- Need careful cleanup when deleting meetings.

---

## ADR-0006 — MVP starts with reliable recording, not advanced AI

Date: 2026-05-25  
Status: Accepted

Context:

The project has many possible advanced features.

Decision:

MVP must prove:

```text
record -> transcribe -> analyze -> save -> review -> export
```

Consequences:

- No WhisperKit in first implementation unless explicitly moved forward.
- No diarization, Calendar, Reminders, CloudKit, widgets, or Apple Foundation Models in MVP 1.
- Faster path to a working app on real iPhone.

---

## ADR-0007 — Use xcodegen for project generation

Date: 2026-05-25
Status: Accepted

Context:

The project needed an `.xcodeproj` to build. Manually constructing a
`project.pbxproj` is error-prone (~500+ lines of opaque plist). The
project had no existing Xcode project file.

Decision:

Use xcodegen (installed via Homebrew) with a `project.yml` spec at the
repo root. The generated `.xcodeproj` is committed to git. Developers
only need xcodegen when the project structure changes (new files,
new targets, new build settings).

Consequences:

- `project.yml` is the human-readable source of truth (~50 lines).
- `.xcodeproj` is committed for convenience (openable without xcodegen).
- Adding new files requires running `xcodegen generate` to update the
  pbxproj, or adding them manually in Xcode.
- CI can regenerate the project from `project.yml` for reproducibility.

---

## ADR-0008 — Home tab instead of Record as top-level tab

Date: 2026-05-25
Status: Accepted

Context:

The initial CLAUDE.md draft listed tabs as Meetings, Record, Chat,
Settings. The UX/UI manual (`docs/ux_ui_manual_ai_meeting_companion.md`)
specifies Home, Meetings, Chat, Settings with recording accessed from
Home via a "Start Meeting" button.

Decision:

Use Home as the first tab. Recording is a destination (full-screen cover
or navigation push from Home), not a tab. The Home tab can grow to
include setup status, recent meetings, and quick actions.

Consequences:

- Better matches the UX/UI manual and iOS navigation conventions.
- RecordView is a called screen, not a fixed tab.
- "Record" as a tab would waste a slot on something used only during
  active meetings; Home provides more utility.

---

## ADR-0009: Navigation pivot to Capture / Inbox / Explore / Chat

**Date:** 2026-05-29

**Decision:** Replace the Home / Knowledge / Ask / Settings tab layout with Capture / Inbox / Explore / Chat.

**Motivation:**

The UX redesign plan identified four product ontology problems with the old navigation:
1. Home mixed recording, project overview, and inbox duties into one overloaded surface
2. Knowledge was a flat "All Items" browser without project-first organization
3. Ask (KnowledgeQueryView) was a lightweight title-search UI not wired to semantic search, giving a poor experience
4. Settings was wasting a primary tab slot

The new structure maps directly to the product ontology:
- **Capture** = create or import sources (record, scan, import, new)
- **Inbox** = find, review, search, and triage all source items
- **Explore** = manage projects/workspaces with project-first layout
- **Chat** = agentic interaction with tool calling

**Alternatives considered:**
- Remove Chat tab per expert panel recommendation. Rejected: the agentic tool calling system makes Chat a differentiated feature.
- Keep Ask tab and wire semantic search. Rejected: Chat with tools subsumes the Ask use case.

**Consequences:**
- KnowledgeQueryView deleted. No dedicated "Ask all items" screen.
- ContentView rewritten with 4-tab layout.
- Explore tab re-centered on Project browsing, not "All Items."
- Inbox tab created as universal search/review surface.

---

## ADR-0010: Agentic chat with tool calling

**Date:** 2026-05-29

**Decision:** Implement an agentic chat system (AgentLoop) that calls tools (GetItem, ListItems, SearchKnowledge, GraphAndTaskTools) rather than simple Q&A.

**Motivation:**

The original "Ask" tab performed lightweight title-based context assembly. This was insufficient for a knowledge workspace where users need to:
1. Query across all items with semantic understanding
2. Get structured responses with citations to source evidence
3. Perform actions like creating items, finding connections, listing project tasks

The AgentLoop architecture enables:
- Streaming responses with tool call / tool result interleaving
- Token budget management via ContextWindowManager
- Extensible tool registry for future capabilities
- Evidence provenance in every response

**Alternatives considered:**
- Wire SemanticSearchService to a simple Q&A UI. Rejected: doesn't support actions or structured queries.
- Use a third-party agent framework. Rejected: adds dependency; our needs are straightforward.

**Consequences:**
- 10 new files in `Domain/Agent/`.
- ChatViewModel uses AgentLoop instead of raw provider calls.
- Tool calls are surfaced in Chat UI as actionable cards.

---

## ADR-0011: VisionKit document scanner for image capture

**Date:** 2026-05-30

**Decision:** Use VisionKit's VNDocumentCameraViewController + Vision VNRecognizeTextRequest for document scanning instead of a custom camera or photo picker.

**Motivation:**

The `.image` KnowledgeItemType existed but was non-functional. Users need to capture documents (contracts, agendas, reports) into their knowledge workspace. VisionKit provides:
- Auto edge detection and perspective correction
- Multi-page scanning in a single session
- Native iOS look and feel
- On-device OCR via Vision framework (no network call)

**Alternatives considered:**
- PHPicker for photo library selection. Rejected: no edge detection, poor document quality.
- Custom AVCaptureSession camera. Rejected: unnecessary complexity; VisionKit already solves the problem.
- Remote OCR API. Rejected: privacy concern; on-device Vision is fast and accurate.

**Consequences:**
- ScannerView wraps VNDocumentCameraViewController via UIViewControllerRepresentable.
- Multiple pages saved as scan_0.jpg, scan_1.jpg, etc. in a single KnowledgeItem.
- OCR text concatenated into bodyText; piped through ContentPipelineService for AI analysis.
- NSCameraUsageDescription added to Info.plist.

---

## ADR-0012: Live Activities for recording status

**Date:** 2026-05-30

**Decision:** Use ActivityKit to show recording timer on the lock screen during active recording.

**Motivation:**

Users lock their iPhone during meetings. A Live Activity shows:
- That recording is active (trust signal)
- Elapsed time
- Paused/resumed state

RecordingCoordinator already publishes state changes and elapsed time via a 1-second timer. Integrating ActivityKit requires minimal additional code.

**Consequences:**
- RecordingActivityAttributes + start/update/stop methods in RecordingCoordinator.
- @preconcurrency import ActivityKit required for Swift 6 Sendable compatibility.
- No Info.plist changes needed.

---

## ADR-0013: ShellInterpreter replaces 47 individual agent tools

**Date:** 2026-06-02

**Decision:** Replace 47 individual agent tool definitions with a single `run_command` tool backed by a Unix-inspired ShellInterpreter and VFS.

**Motivation:**

As the agent system grew, the tool list became unwieldy. Each new capability required a new tool definition, bloating the context window and making tool selection harder for the LLM. The Unix shell model is natively understood by LLMs, composable via pipes, and infinitely extensible without new tool definitions.

**Consequences:**
- Single `ShellTool.run_command` replaces all previous tools.
- ShellInterpreter tokenizes and dispatches 24 commands (ls, cd, cat, find, grep, touch, echo, rm, mv, head, wc, history, extract, semantic, analyze, cal, person, export, vision, describe, progress, cleanup, recipe, help, ask_user).
- VFSService maps domain objects to virtual filesystem paths (15 path types).
- AgentLoop context window shrinks ~60% (one tool schema vs 47).
- New capabilities added as new ShellInterpreter commands, not new tools.

---

## ADR-0014: Project frameworks as LLM-defined schemas

**Date:** 2026-06-04

**Decision:** Project frameworks use LLM-authored JSON schemas instead of hardcoded Swift enums, enabling users and AI to define custom frameworks without app updates.

**Motivation:**

Hardcoded framework types (meeting, research, etc.) cannot cover all user needs. A legal team needs different fields than a product team. LLM-defined schemas allow frameworks to adapt without code changes, while still being validated at runtime.

**Consequences:**
- FrameworkService loads schemas from `ai_config.json` and user overrides.
- DynamicAnalysis renders UI from JSON schema, not hardcoded views.
- 5 built-in frameworks shipped (meeting, research, brainstorm, journal, blank).
- Users can add custom frameworks via config project.
- Validation at pipeline run time — malformed schemas fail gracefully.

---

## ADR-0015: Chat blocks as structured output types

**Date:** 2026-06-06

**Decision:** Render LLM output as typed ChatBlock structs rather than raw markdown, enabling rich interactive UI elements in chat.

**Motivation:**

Raw markdown limits chat to text. Structured blocks enable: interactive task cards, collapsible analysis sections, choice prompts, progress bars, file previews. Each block type has a dedicated SwiftUI view builder.

**Consequences:**
- 18 ChatBlock types defined in ChatModels.swift.
- ContentParser heuristically parses markdown into blocks.
- Streaming renders partial blocks with `isStreaming` flag.
- New block types added via enum case + view builder.
- Block type JSON schemas documented in CHAT_BLOCK_RENDERING.md.

---

## ADR-0016: Anarlog ecosystem as import/export bridge

**Date:** 2026-06-08

**Decision:** Build the Anarlog ecosystem as a bidirectional import/export bridge with external tools, using watched folder sync and quality validation gates.

**Motivation:**

Users have meeting data in other systems (Meetily, manual transcripts). Anarlog provides a standard interchange format with quality validation (EvalSystem), speaker labeling, and template mapping, allowing data to flow in and out of Wawa Note without vendor lock-in.

**Consequences:**
- 15 files in Ecosystem/Anarlog/.
- AnarlogSyncService watches folders for new files, auto-imports.
- EvalSystem validates AI output quality before ingestion.
- SpeakerLabeler cross-references Contacts for identity resolution.
- VoiceActivityDetector integration for precise segment timing.
- MeetilyImporter/Exporter for Meetily ecosystem compatibility.
