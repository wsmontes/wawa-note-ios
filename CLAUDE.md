# CLAUDE.md — Wawa Note

Updated: 2026-06-12

## Dev workflow (automated)

```bash
# ── Build & Deploy ────────────────────────────
make all                              # Build → Install → Test (default: iPhone 14 Plus)
make all DEVICE=15                    # Build → Install → Test on iPhone 15
make deploy                           # Build → Install (no tests)
make quick                            # Build + test (no install)
make test                             # Run unit tests on simulator
make clean                            # Clear DerivedData

# ── Log Pipeline ──────────────────────────────
make logs                             # Stream real-time logs (iPhone 14 Plus)
make logs DEVICE=15                   # Stream real-time logs (iPhone 15)
make logs-save                        # Stream + save to ~/Desktop/wawa-logs/
make tail                             # Quick last-100 lines snapshot
make bug-logs since=1h                # Collect last hour of logs (post-hoc)
make bug-logs DEVICE=15 since=30m     # Collect from iPhone 15, last 30 min
make bug-logs since=2h crashes=1      # + crash reports
make bug-report since=1h              # Full bug report bundle (logs + crashes + device info)
make devices                          # List configured test devices

# ── Manual log operations ─────────────────────
bash scripts/log-capture.sh stream 14plus --save
bash scripts/log-capture.sh collect 14plus --since 1h --crashes --bundle
bash scripts/log-capture.sh tail 14plus 200
bash scripts/dev-automation.sh all 14plus
```

**Test devices:**
| Device | UDID | iOS | Role |
|--------|------|-----|------|
| iPhone 14 Plus | `00008110-00067D861486201E` | 18.6.2 | Primary tester |
| iPhone 15 | `00008120-000260903ED1A01E` | 26.5 | Secondary |
| iPhone 14 Plus Simulator | `91BF4C97-...` | 26.5 | Automated tests |

**Device config:** `scripts/device-config.sh` — single source of truth for all device identities.
**Log pipeline:** `scripts/log-capture.sh` — stream, collect, tail modes for real-time + post-hoc.

## Project identity

Native iOS app for iPhone: **local-first AI workspace for project memory**.

> Capture meeting evidence → canonical knowledge store → derived project graph → semantic retrieval with provenance.

Records meetings, transcribes audio, extracts structured intelligence, organizes items into projects, builds typed graph relationships with evidence provenance, scans documents via VisionKit OCR, and supports multiple AI providers through clean abstractions. Agentic chat with tool calling is wired.

**Product thesis (from `docs/deep-research-report.md`):** Meeting evidence becomes reusable project memory, and project memory becomes an explorable graph with tasks, decisions, owners, and connected artifacts.

## Source-of-truth documents

Read these before making architecture decisions:

1. `docs/deep-research-report.md` — strategic direction, competitive analysis, target architecture.
2. `docs/IMPLEMENTATION_PLAN_V2.md` — actionable task plan with 5 waves.
3. `docs/APPLE_TECH_INVENTORY.md` — Apple/iPhone 14 Plus technical constraints.
4. `docs/CODING_STANDARDS.md` — coding rules and conventions.
5. `docs/API_PROVIDER_CONTRACTS.md` — provider and transcription abstractions.
6. `docs/SECURITY_PRIVACY.md` — permissions, secrets, privacy modes.
7. `docs/DECISIONS.md` — architecture decision records.
8. `docs/expert_panel_review.md` — expert feedback and UX recommendations.

Archived docs (meeting-recorder MVP era) live in `docs/history/`.

## Evolution timeline

The codebase has evolved through these phases (oldest first):

1. **Meeting-recorder MVP** — `docs/history/` documents. Recording, transcription, analysis, export.
2. **Transformation plan** — `docs/TRANSFORMATION_PLAN.md`. Added KnowledgeItem, Folder, Annotation, context sensors, semantic search.
3. **Implementation Plan V2** — `docs/IMPLEMENTATION_PLAN_V2.md`. Project, Task, Person, GraphEdge models. Agent system. Calendar, Reminders.
4. **Navigation pivot** — `docs/Interface Frameworks for Wawa-note.md` (2026-05-29). Replaced Home/Knowledge/Ask/Settings with Capture/Inbox/Explore/Chat.
5. **UX redesign plan** — Memory file `project_ux_redesign_plan.md`. 9-phase UX polish plan.
6. **Wave 0 — iOS integration hardening** — Memory file `wave0_ios_integration_hardening.md`. 36 fixes across Calendar, Reminders, Location, Audio, Share Extension, Watch, Export, Import.
7. **Wave 1 — New iOS integrations** — `docs/../plans/giggly-finding-cocoa.md`. Vision OCR document scanner, Live Activities, Core Spotlight, Contacts, Face ID, Calendar OUT.

## Current state

The codebase is in **late-stage transformation** from meeting recorder to knowledge workspace. The foundation models (Project, Task, Person, GraphEdge, Entity) are built and registered in ModelContainer. The agentic chat system is wired with tool calling. iOS ecosystem integrations have been hardened and extended.

### What's solid

- **KnowledgeItem** — polymorphic model: meeting, note, journalEntry, webBookmark, image.
- **Project, TaskItem, Person, GraphEdge, Entity** — all first-class SwiftData models with services.
- **Agent system** — AgentLoop with streaming, tool calling (GetItem, ListItems, SearchKnowledge, GraphAndTaskTools).
- **Content pipeline** — unified extract → analyze → ingest for all item types.
- **Import pipeline** — 10 importers via FormatImporter protocol + Share Extension.
- **Export pipeline** — Markdown, JSON, SRT, CSV, Graph JSON + Reminders export + Calendar create.
- **Context sensors** — Calendar, AudioRoute, Location, Battery, MotionActivity, FocusMode.
- **iOS integrations** — Calendar read/write, Reminders export, Watch Connectivity, Live Activities, Vision OCR document scanner (multi-page), Core Spotlight indexing, Contacts speaker matching, Face ID gate.
- **Provider abstraction** — OpenAI, Anthropic, Gemini, OpenAI-compatible + remote/local transcription engines.
- **Calendar timeline** — MonthGrid, DayActivity, OnThisDay, unified EKEvent + KnowledgeItem view.
- **27 unit tests** in `CoreServicesTests.swift`.

### Navigation (current)

**4 tabs:** Capture, Inbox, Explore, Chat (ContentView.swift).

| Tab | Purpose |
|---|---|
| Capture | Record meetings, scan documents, import files — primary action surface |
| Inbox | Global search and triage of all source items |
| Explore | Project-first workspace browser with Timeline |
| Chat | Agentic AI chat with tool calling (AgentLoop) |

### What's still in progress

- **CrossReferenceResult** — Connection, Insight, Contradiction exist as ephemeral DTOs, not yet persisted as GraphEdges.
- **SemanticSearchService + EmbeddingService** — exist but not wired to any UI surface.
- **On-device LLM** — ModelDownloadService and ModelRegistry exist. llama.cpp inference not wired.
- **Phase 8 device validation** — never tested on iPhone 14 Plus hardware.
- **Live Activities** — implemented, needs real-device test during recording.
- **KnowledgeQueryView** — deleted. No dedicated "Ask all items" screen. Chat tab serves this role.

### iOS ecosystem integrations

| Integration | Direction | Status |
|---|---|---|
| Calendar read + context sensor | IN | Implemented |
| Calendar create events | OUT | Implemented |
| Reminders export | OUT | Implemented |
| Reminders read context | IN | Not yet |
| Share Extension | IN | Implemented |
| Format importers (10) | IN | Implemented |
| Export (MD, JSON, SRT, CSV, Graph) | OUT | Implemented |
| Context sensors (7) | IN | Implemented |
| Watch Connectivity | BOTH | Implemented |
| Apple Speech transcription | IN | Implemented |
| Live Activities | OUT | Implemented |
| Vision OCR doc scanner | IN | Implemented |
| Core Spotlight indexing | OUT | Implemented |
| Contacts speaker matching | IN | Implemented |
| Face ID biometric gate | INTERNAL | Implemented |
| App Intents / Siri | — | Not implemented (needs extension target) |
| WeatherKit sensor | — | Not implemented (needs entitlement) |

## Module layout

```text
wawa-note/
  App/                WawaNoteApp.swift
  Audio/              Capture, Playback, Session, FileWriter
  Connectivity/       Watch session, RecordingCoordinator
  ContextCapture/     Calendar, Location, Focus, Motion, Battery, AudioRoute sensors
  Domain/
    Agent/            AgentLoop, AgentTool, ToolRegistry, ContextWindow, Tools/
    Calendar/         CalendarEvent, CalendarSyncService, TimelineEntry, DaySummary, OnThisDay
    Models/           KnowledgeItem, Folder, Annotation, ProjectModels (Project, TaskItem, Person, GraphEdge, Entity), ChatModels, CrossReferenceModels
    Services/         KnowledgeItemService, ProjectService, TaskService, PersonService, GraphEdgeService, ContentPipelineService, ContentExtractionService, SearchService, ChatService, ...
  Ecosystem/
    Export/           ExportService, MarkdownExporter, JSONExporter, ProjectExportService, TaskRemindersService
    Import/           ImportRouter, FormatImporter, ICS/JSON/Markdown/SRT/PDF/HTML/RTF/GitHubIssues importers
    Spotlight/        (SpotlightIndexService in SearchService.swift)
  LocalIntelligence/  EmbeddingService, SemanticSearchService
  Providers/          AIProvider, OpenAICompatibleProvider, AnthropicProvider, GeminiProvider, ProviderAdapter, ProviderRouter
  Security/           (BiometricGateService in WawaNoteApp.swift)
  Storage/            FileArtifactStore, SecureKeyStore
  Transcription/      AppleSpeechTranscriptionEngine, RemoteTranscriptionEngine
  UI/
    Capture/          ScannerView, ScannerViewModel (in HomeView.swift)
    Home/             HomeView, CaptureViewModel
    Inbox/            InboxView
    Explore/          ExploreView
    Chat/             ChatView, ChatViewModel
    Project/          ProjectDetailView, ProjectTimelineView, ProjectGraphView, ProjectTaskBoardView, PromoteToProjectSheet
    Knowledge/        KnowledgeDetailView, ConnectionsFeedView
    Calendar/         CalendarContainerView (TimelineExplorerView, MonthGridView, DayCellView, DayActivityView, OnThisDayView)
    Components/       ContentView, CreationSheetView, PermissionPromptView, PrimaryActionButton, EmptyStateView
    Import/           ImportFormView
    Settings/         SettingsView, ProviderPickerView, ProviderConnectView
  Utilities/          Logging, AppDesign
```

## Hard constraints

- Target first real device: **iPhone 14 Plus**.
- Do not make Apple Intelligence or Foundation Models a required feature.
- Do not implement a backend unless explicitly requested.
- Do not hard-code API keys, provider URLs, or secrets.
- Use Keychain for API keys.
- Use FileManager for large artifacts (audio, transcript, analysis JSON, scanned images).
- Use SwiftData for metadata and indexable records.
- Do not put audio/transcription/networking logic directly inside SwiftUI views.
- Do not let provider-specific JSON leak across the app.
- Keep original raw audio and original transcript recoverable unless user deletes them.
- **Provenance on every edge:** graph relationships must be traceable to a transcript segment, note block, or external event.

## Architectural rules

Protocol-first boundaries:

```swift
protocol AIProvider { ... }
protocol TranscriptionEngine { ... }
protocol FormatImporter { ... }
protocol FormatExporter { ... }
protocol ContextSensor { ... }
```

Provider-specific implementations belong under Providers/, not in views.

### Graph data discipline

- Graph edges must always carry provenance: `sourceItemID` + `sourceSegmentIDs`.
- Connections discovered by AI must be confirmed or reviewed before persisting as GraphEdges.
- Never delete source evidence when deleting a derived edge or task.

### SwiftData rules

- No `@Relationship` cascade deletes — use manual recursive delete in service layer.
- Folder hierarchy uses `parentFolderID: UUID?` (nil = root), not SwiftData relationships.
- Annotation uses upsert pattern: delete existing for (itemID, source), insert new ones.

### File discipline

- New files must be added to `wawa-note.xcodeproj/project.pbxproj` (via Xcode, not manually).
- Files created outside Xcode won't compile. Embed code in existing files or add to pbxproj.
- Prefer small files with clear responsibilities.

## Swift style

- Swift Concurrency (`async/await`) for async flows.
- `@MainActor` for UI-facing view models.
- `@preconcurrency import` for Apple frameworks not yet audited for Sendable (ActivityKit, etc.).
- `@unchecked Sendable` + explicit locking for classes that must bridge non-Sendable system APIs.
- Keep SwiftUI views thin. Services testable without UI.
- Dependency injection through initializers. Avoid global mutable singletons unless wrapping system APIs.
- Strongly typed models over dictionaries. Typed error enums.

## AI request rules

**Every AI call must use `AIConfigService.shared.requestParams(for:model:)`.** Never hardcode `temperature` or `maxTokens` in individual services.

```swift
// CORRECT
let params = AIConfigService.shared.requestParams(for: "analysis", model: model)
let request = AIRequest(model: model, messages: [...],
    temperature: params.temperature,
    maxTokens: params.maxTokens,
    responseFormat: .jsonObject)

// WRONG — hardcoded values bypass config and break on reasoning models
let request = AIRequest(model: model, messages: [...],
    temperature: 0.4, maxTokens: 4096, responseFormat: .jsonObject)
```

`requestParams` handles internally: reasoning model detection (temperature → nil), feature config ceiling, model preset caps, and context window for chunking. Services only own their system/user prompts.

## Implementation behavior

1. Inspect existing files first.
2. Build and run on device when available.
3. Update this file and `docs/DECISIONS.md` when architectural decisions change.
4. Prefer editing existing files to creating new ones (pbxproj limitation).
5. **Always reference JIRA issues** — see JIRA Workflow below.

## JIRA Workflow

**Project:** KAN at https://wawasoftbc.atlassian.net (auth: wawasoftbc@gmail.com + API token)
**Client:** `C:\workspace\_archive\wawasoft_jira_client.py` (JiraClient class, cloud API v3)

### Before starting work

1. **Check the board** — query JIRA for the relevant issue(s) before starting. Use `jira("show KAN-XX")` to get acceptance criteria and related issues.
2. **Transition to In Progress** — `jira("move KAN-XX \"In Progress\"")`
3. **Create branch with issue key** — `git checkout -b KAN-XX/short-description`

### During work

4. **Commit messages must include JIRA key** — `git commit -m "KAN-73: fix AAC decoding for SFSpeechRecognizer"`
5. **Reference related issues** — if work touches multiple issues, mention all: `KAN-73, KAN-79: switch AudioChunker to PCM WAV`
6. **Comment on JIRA with progress** — `jira("comment KAN-XX 'Implemented PCM path, testing on device'")`

### After completing work

7. **Transition to Done** — `jira("move KAN-XX Done")`
8. **Link related issues discovered during work** — `jira("link KAN-XX KAN-YY --type Relates")`
9. **Create new issues for discovered work** — don't silently add scope; create a new JIRA issue.

### JIRA reference in code

Every Swift file has a `// Related JIRA: KAN-XX, KAN-YY` comment after imports. When modifying a file:
- Verify the JIRA references are still accurate
- Add new JIRA keys if the file now relates to additional issues
- Use the referenced JIRAs to understand the file's purpose and acceptance criteria

### Key queries

```python
from wawasoft_jira_client import JiraClient
c = JiraClient()
c.jira("mine")                           # My open issues
c.jira("search 'keyword' -p KAN")        # Search by keyword
c.jira("show KAN-73 --comments --links") # Full issue details
c.jira("recent KAN -n 10")              # Recent activity
c.jira("children KAN-5")                # All items under an epic
```

### Sprint priorities

- **Sprint 1 (label: sprint:1):** P0 bugs + dogfooding + state machine
- **Sprint 2 (label: sprint:2):** God object splits + DI + tests
- **Sprint 3 (label: sprint:3):** Chat UX + onboarding + kanban

### Confluence documentation

Architecture, data flow, and provider guides live in Confluence (wawasoftbc.atlassian.net/wiki). Key issues are linked to their relevant Confluence pages via remote links. Check the issue's links section for documentation references.

## When uncertain

Choose the simpler option that preserves the architecture.

Consult `docs/deep-research-report.md` for strategic direction.
