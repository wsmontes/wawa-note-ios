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

## ADR-0013: V1 scope is Capture / Inbox / Explore with collection-only Projects

**Date:** 2026-07-19

**Status:** Accepted

**Related JIRA:** KAN-533

**Decision:** Ship v1 with three primary tabs—Capture, Inbox, and Explore. Remove Chat from the user-facing navigation and runtime initialization. Treat a Project as a user-named collection of source `KnowledgeItem` records, without project-level synthesis, ingestion, tasks, signals, health scoring, or graph UI.

**Motivation:**

The release audit found that the `mvp-v2` branch had reintroduced the global Chat tab and project-agent pipeline even though the prior v1 simplification was recorded as complete in KAN-518/KAN-519/KAN-523. Those surfaces add large, provider-dependent, weakly tested execution paths to the release-critical capture and review loop. The product must first prove that users can reliably capture, transcribe, analyze, organize, recover, and export source evidence.

**Alternatives considered:**

- Keep global Chat as a fourth tab. Rejected for v1 because it dilutes the capture-and-memory product and materially expands the test matrix.
- Keep Chat only inside Projects. Rejected for v1 because it still requires project-scoped agent/VFS behavior and provider setup in the primary organization surface.
- Keep automatic Project synthesis. Rejected because Projects need predictable collection semantics before derived multi-item intelligence can be trusted.
- Remove all chat, graph, task, and derived-data models immediately. Rejected because deleting persisted schema at release time creates unnecessary migration and evidence-loss risk.

**Consequences:**

- ADR-0009 is superseded for v1 navigation; ADR-0010 remains an implemented post-v1 capability, not a shipping surface.
- `ContentPipelineService` performs source extraction, transcription, analysis, embedding, and indexing only. It no longer initializes or calls `ProjectIngestionPipeline`.
- Project screens list source items and support record, note, import, remove, and export operations.
- Existing derived models and implementation files remain in the binary temporarily for data compatibility, but are unreachable from v1 UI and are not initialized.
- Deleting a Project detaches and preserves its source items.
- Sensitive permissions are requested only when the user invokes the related feature. Recording captures non-sensitive audio-route and battery metadata by default; it does not automatically access calendar, location, motion, or Focus status. The app does not request notification permission at launch.

---

## ADR-0014: Cloud AI requires provider-specific content-sharing consent

**Date:** 2026-07-19

**Status:** Accepted

**Related JIRA:** KAN-539

**Decision:** A cloud AI provider cannot receive recordings, transcripts, notes, scans, imported text, images, or embeddings until the user explicitly approves content sharing for that provider. The approval timestamp is stored with `AIProviderConfigModel`; local providers are exempt because processing stays on user-controlled devices.

**Motivation:** Adding an API key establishes authentication, but it does not clearly disclose or authorize transmission of personal content. App Review Guideline 5.1.2 requires clear disclosure and explicit permission before personal data is shared with a third-party AI service.

**Consequences:**

- Cloud provider connection and custom-provider editing include an off-by-default content-sharing control with provider-specific disclosure.
- Provider resolution rejects unapproved cloud configurations, including configurations migrated from older app versions.
- Remote transcription falls back to the on-device Apple engine when the active cloud provider has no approval.
- Connection tests and model-list discovery may run without approval because they do not include the user's stored content.
