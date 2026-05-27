# CLAUDE.md — Wawa Note

## Project identity

This is a native iOS app for iPhone: **local-first AI workspace for project memory**.

Core idea:

> Capture meeting evidence → canonical knowledge store → derived project graph → semantic retrieval with provenance.

The app records meetings, transcribes audio, extracts structured intelligence, organizes knowledge items into projects, builds typed graph relationships with evidence provenance, and supports multiple AI providers through clean abstractions.

**Product thesis (from `docs/deep-research-report.md`):** Meeting evidence becomes reusable project memory, and project memory becomes an explorable graph with tasks, decisions, owners, and connected artifacts.

## Source-of-truth documents

Before making architecture decisions, read these files:

1. `docs/deep-research-report.md` — strategic direction, competitive analysis, target architecture.
2. `docs/TRANSFORMATION_PLAN.md` — concrete implementation blueprint, data model, file layout.
3. `docs/IMPLEMENTATION_PLAN_V2.md` — actionable task plan with 5 waves and priorities.
4. `docs/APPLE_TECH_INVENTORY.md` — Apple/iPhone 14 Plus technical constraints.
5. `docs/CODING_STANDARDS.md` — coding rules and conventions.
6. `docs/API_PROVIDER_CONTRACTS.md` — provider and transcription abstractions.
7. `docs/SECURITY_PRIVACY.md` — permissions, secrets, privacy modes.
8. `docs/DECISIONS.md` — architecture decision records.
9. `docs/expert_panel_review.md` — expert feedback and UX recommendations.
10. `docs/wawa_note_import_audit.md` — import pipeline audit and fixes.

Archived docs (meeting-recorder MVP era) live in `docs/history/`.

## Current state

The codebase is in **mid-transition** from meeting recorder to knowledge workspace:

- **KnowledgeItem** (polymorphic: meeting, note, journalEntry, webBookmark, image) replaces MeetingModel.
- **Folder** hierarchy and **Annotation** key-value system exist.
- **CrossReferenceResult** (Connection, Insight, Contradiction) exists as ephemeral DTOs — not yet persisted.
- **SemanticSearchService** and **EmbeddingService** exist but are not wired to the Ask UI.
- **MeetingModel** is still registered in ModelContainer alongside KnowledgeItem.
- **Chat** models (ChatConversationModel, ChatMessageModel) are still registered but no longer primary navigation.
- **Templates** (ask, analyze, compare, expand, organize) and **Lenses** exist in Resources/templates/.
- **MigrationService** converts MeetingModel → KnowledgeItem on first launch.
- Current navigation: Home, Knowledge, Ask, Settings.

### Critical gaps (priority order)

1. **No Project model** — items cannot be grouped into projects
2. **No Task model** — action items are not first-class entities
3. **No GraphEdge model** — connections are ephemeral, not persisted
4. **No Person/Entity models** — people and entities mentioned are not tracked
5. **Ask not wired to SemanticSearch** — uses lightweight title-based context
6. **No unit tests** — every new feature adds fragility
7. **Phase 8 (device validation) not done** — never tested on iPhone 14 Plus

See `docs/IMPLEMENTATION_PLAN_V2.md` for the full task breakdown.

## Target architecture

Four-layer architecture (from `docs/deep-research-report.md`):

```
Capture layer           → Canonical local store    → Extraction pipeline
(Recording, Import,      (SwiftData + FileManager   (ASR, summarization,
 Share, Calendar,        + typed edge store)         entities, decisions,
 Context sensors)                                     actions, embeddings)

                        ↓

Derived projections      → Retrieval / Assistant    → UI surfaces
(Project view,            (Semantic search,           (Home, Knowledge,
 Task view, Timeline,     Ask with evidence           Project, Ask,
 Graph views)             citations)                  Graph views)
```

### Current module layout

```text
wawa-note/
  App/              WawaNoteApp.swift
  Audio/            Capture, Playback, Session, FileWriter
  Connectivity/     Watch session, RecordingCoordinator
  ContextCapture/   Calendar, Location, Focus, Motion, Battery, AudioRoute sensors
  Domain/
    Models/         KnowledgeItem, Folder, Annotation, CrossReferenceModels, AITemplate, ...
    Services/       KnowledgeItemService, FolderService, CrossReferenceService, ...
    Calendar/       CalendarEvent, CalendarSyncService
  Ecosystem/
    Export/         ExportService, MarkdownExporter, JSONExporter
    Import/         ImportRouter, FormatImporter, ICS/JSON/Markdown/SRT importers
  LocalIntelligence/ EmbeddingService, SemanticSearchService
  Providers/        AIProvider, OpenAICompatibleProvider, ProviderAdapter, ProviderRouter
  Storage/          FileArtifactStore, SecureKeyStore
  Transcription/    AppleSpeechTranscriptionEngine, RemoteTranscriptionEngine
  UI/
    Home/           HomeView
    Knowledge/      KnowledgeListView, KnowledgeDetailView, KnowledgeQueryView, ConnectionsFeedView
    Recording/      RecordView, RecordingViewModel
    Settings/       SettingsView, ProviderPickerView, ProviderConnectView, ...
    Calendar/       CalendarContainerView, DayTimelineView
    Components/     ContentView, AppStatusBadge, PrimaryActionButton, EmptyStateView
    Import/         ImportFormView
  Utilities/        Logging, AppDesign
```

## Hard constraints

- Target first real device: **iPhone 14 Plus**.
- Do not make Apple Intelligence or Foundation Models a required feature.
- Do not implement a backend unless explicitly requested.
- Do not hard-code API keys, provider URLs, or secrets.
- Do not store secrets in SwiftData, JSON, UserDefaults, or source files.
- Use Keychain for API keys.
- Use FileManager for large artifacts (audio, transcript JSON, embeddings).
- Use SwiftData for metadata and indexable records (items, folders, annotations, projects, tasks, edges).
- Do not put audio/transcription/networking logic directly inside SwiftUI views.
- Do not let provider-specific JSON leak across the app.
- Keep audio, transcript, analysis, and retrieval as separate layers.
- Keep original raw audio and original transcript recoverable unless the user deletes them.
- **Provenance on every edge:** graph relationships must be traceable to a transcript segment, note block, or external event.

## Architectural rules

Use protocol-first boundaries:

```swift
protocol AIProvider { ... }
protocol TranscriptionEngine { ... }
protocol AudioCaptureService { ... }
protocol SecureKeyStore { ... }
protocol FormatImporter { ... }
protocol ContextSensor { ... }
```

Provider-specific implementations belong under provider modules, not in views.

### Graph data discipline

- Graph edges must always carry provenance: `sourceItemID` + `sourceSegmentIDs`.
- Connections discovered by AI must be confirmed or reviewed before persisting as GraphEdges.
- Use confidence thresholds for auto-created edges; require human confirmation for low-confidence edges.
- Never delete source evidence when deleting a derived edge or task.

### SwiftData rules

- No `@Relationship` cascade deletes — use manual recursive delete in service layer.
- Folder hierarchy uses `parentFolderID: UUID?` (nil = root), not SwiftData relationships.
- Annotation uses upsert pattern: delete existing for (itemID, source), insert new ones.

## Implementation behavior

For any non-trivial change:

1. Inspect existing files first.
2. Update `docs/IMPLEMENTATION_PLAN_V2.md` task status before and after implementation.
3. Make one coherent change at a time.
4. Prefer small files with clear responsibilities.
5. Run build when available.
6. Update docs when architectural decisions change.
7. Record important decisions in `docs/DECISIONS.md`.

## Current priority (Wave 0 — Stabilization)

1. Remove legacy models from ModelContainer (MeetingModel, ChatConversationModel, ChatMessageModel).
2. Remove legacy UI (Meetings/, Chat/ directories).
3. Verify build and all flows functional after cleanup.
4. Then proceed to Wave 1: Project, Task, Person, GraphEdge models.

See `docs/IMPLEMENTATION_PLAN_V2.md` Wave 0 for the detailed task list.

## Swift style

- Use Swift Concurrency (`async/await`) for async flows.
- Use `@MainActor` for UI-facing view models.
- Use `ObservableObject` or modern Observation depending on project target.
- Keep SwiftUI views thin.
- Keep services testable without UI.
- Prefer dependency injection through initializers.
- Avoid global mutable singletons unless wrapping stable system APIs.
- Prefer strongly typed models over dictionaries.
- Handle errors explicitly with typed error enums where practical.

## When uncertain

Choose the simpler option that preserves the architecture.

Consult `docs/deep-research-report.md` for strategic direction.

Document uncertainty in `docs/DECISIONS.md` instead of overbuilding.
