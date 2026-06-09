# Wawa Note — Project Overview

> **Native iOS workspace for personal knowledge management with AI agent.**
> Capture evidence → canonical knowledge store → derived project graph → semantic retrieval.

**Target device:** iPhone 14 Plus | **iOS:** 17.0+ | **Language:** Swift 6 | **Database:** SwiftData | **Last updated:** 2026-06-07

---

## Table of Contents

1. [Architecture](#architecture)
2. [Navigation & Tabs](#navigation--tabs)
3. [KnowledgeItem Types](#knowledgeitem-types)
4. [Virtual Filesystem](#virtual-filesystem)
5. [AI Agent System](#ai-agent-system)
6. [Content Pipeline](#content-pipeline)
7. [Capture & Scanning](#capture--scanning)
8. [iOS Ecosystem Integrations](#ios-ecosystem-integrations)
9. [Security & Privacy](#security--privacy)
10. [Module Layout](#module-layout)

---

## Architecture

Wawa Note follows a **protocol-first, local-first** architecture. All data lives on the device. AI providers are pluggable through the `AIProvider` protocol. The app has no backend.

### Core Principles

- **Local-first** — SwiftData for metadata, FileManager for artifacts (audio, images, transcripts, analysis)
- **Protocol boundaries** — `AIProvider`, `TranscriptionEngine`, `FormatImporter`, `FormatExporter`, `ContextSensor`
- **UUID foreign keys** — No SwiftData `@Relationship` macros; all joins are manual via `FetchDescriptor` predicates
- **Provenance on every edge** — Graph relationships must be traceable to a source transcript segment, note block, or external event
- **Agent-first design** — A virtual filesystem (VFS) gives the AI agent and the user the same mental model of the data

### Dual Persistence Strategy

| Data Type | Storage | Location |
|-----------|---------|----------|
| KnowledgeItems, Projects, Tasks, People, Edges, Signals | SwiftData | Default SQLite store |
| Audio files | FileManager | `Application Support/Meetings/items/{uuid}/audio.m4a` |
| Transcripts, Analyses, Embeddings | FileManager (JSON) | `Application Support/Meetings/items/{uuid}/*.json` |
| Scanned images | FileManager (JPEG) | `Application Support/Meetings/items/{uuid}/scan_*.jpg` |
| Chat conversations | FileManager (JSON) | `Application Support/Meetings/Chat/*.json` |
| Prompt overrides, Agent memories | FileManager (JSON) | `Application Support/Meetings/configs/*.json` |
| API keys | iOS Keychain | Secure Enclave-backed |

---

## Navigation & Tabs

The app uses a 4-tab layout (`ContentView.swift`):

| Tab | Label | Purpose |
|-----|-------|---------|
| **Capture** | `mic.badge.plus` | Record audio, scan documents, take photos, scan QR/barcodes, Live OCR, import files |
| **Inbox** | `tray` | Universal search and triage of all source items. Trash management |
| **Explore** | `rectangle.grid.1x2` | Projects list, **Files browser** (VFS Finder-like), Calendar Timeline |
| **Chat** | `bubble.left.and.bubble.right` | AI agent chat overlay with tool calling and streaming responses |

### Explore Tab — 3 Views

- **Projects** — Flat list with search, sort, health badges
- **Files** — Finder-like VFS browser with breadcrumbs, back/forward/parent, sort, context menus (rename, duplicate, export, delete)
- **Timeline** — Calendar month grid with day detail view

---

## KnowledgeItem Types

### 1. Audio (`audio`)
- **Captured via:** Recording (microphone), file import, share extension
- **Stored as:** `audio.m4a` in item directory
- **Processing:** Transcription → Analysis → Embeddings → Spotlight indexing
- **Analysis output:** `transcript.json`, `analysis.json` (MeetingAnalysis: summary, decisions, action items, risks, entities)
- **Visualization:** Audio player in detail view + transcript with timestamped segments + analysis cards
- **Agent can:** Create (without audio data), read, update metadata, trigger transcription, export, cleanup raw audio

### 2. Note (`note`)
- **Captured via:** CreationSheetView → NoteEditorView, file import (text, markdown, PDF, HTML, RTF), agent `touch`
- **Stored as:** `bodyText` in SwiftData + `body.md` on disk (defense in depth)
- **Processing:** Pipeline agent analysis, embedding generation
- **Visualization:** RichBodyView with ContentParser (tables, lists, code blocks rendered natively)
- **Agent can:** Create with full markdown body, append via `>>`, export, batch process with `find --exec`

### 3. Journal Entry (`journalEntry`)
- **Captured via:** CreationSheetView → JournalEditorView (with mood picker), agent `touch --mood`
- **Stored as:** `bodyText` + `body.md`, mood as `mood/*` tag
- **Processing:** Same pipeline as notes
- **Visualization:** RichBodyView + mood badge (emoji + color) in detail header
- **Moods:** great 😄, good 🙂, okay 😐, bad 😞, terrible 😢, anxious 😰, excited 🤩, tired 😴, grateful 🙏, productive 💪, reflective 🤔

### 4. Web Bookmark (`webBookmark`)
- **Captured via:** CreationSheetView (URL alert), agent `touch --url`
- **Stored as:** `importSourceURL` in SwiftData
- **Processing:** URL content fetching (HTML → plain text, 8000 char limit), pipeline analysis
- **Visualization:** Preview card with favicon, host, Open/Copy URL buttons
- **Export:** Markdown and JSON supported
- **Agent can:** Create with `--url` flag, fetch content for analysis

### 5. Image (`image`)
- **Captured via:** Camera, Photo gallery, Document scanner (VisionKit), file import, share extension
- **Stored as:** `scan_*.jpg` in item directory, metadata in SwiftData
- **Processing:** Apple Vision OCR + LLM vision analysis → `bodyText`, Spotlight indexing
- **Visualization:** Pageable gallery with swipe-to-delete, extracted text display
- **Page management:** Swipe left to delete pages, auto re-indexing
- **Agent can:** Analyze with `vision` command, `--save-as-note`

---

## Virtual Filesystem

The VFS provides a unified namespace for both user and AI agent to navigate the knowledge workspace. It is implemented in `VFSService` (shared resolution) and rendered in `FileBrowserView` (Finder-like UI).

### Directory Structure

```
/                                          Root — workspace summary
/inbox/                                    Items without a project
  {item-uuid}/                             Item directory
    body.md                                Note/journal body text
    metadata.json                          Item metadata (all fields)
    audio.m4a                              Audio recording
    transcript.json                        Transcription segments
    analysis.json                          MeetingAnalysis
    analysis.dynamic.json                  Framework-driven analysis
    scan_0.jpg, scan_1.jpg, ...            Scanned/captured images
    exports/                               Exported files
/projects/                                 All projects
  {project-slug}/                          Project directory
    project.json                           Project metadata
    items/                                 KnowledgeItems in this project
    tasks/                                 Tasks by status/priority
    people/                                People connected via graph edges
    edges/                                 Graph relationships
    signals/                               Active alerts and insights
    analysis/                              AI analysis per item
  wawa-note-config/                        System configuration project (auto-created)
    providers/                             AI provider configurations
    prompts/                               Prompt templates
    settings/                              App preferences
    memories/                              Agent learned patterns
/agent/                                    Agent workspace
  prompts/                                 Editable prompt templates
  memories/                                Learned strategies
  chat/                                    Conversation history
```

### FileBrowser Features

- **Finder-like navigation:** Back/Forward/Parent buttons, breadcrumb path bar
- **Sort:** Name, Date, Kind, Size
- **Context menu (long press):** Open, Rename, Duplicate, Move, Export, Delete, Get Info
- **Swipe actions:** Leading (Rename, Move), Trailing (Delete)
- **Editors:** Markdown (Edit/Preview modes), JSON (Form/Pretty/Raw modes), Audio player, Image viewer (pinch-to-zoom)
- **JSON Form mode:** Adaptive UI that renders any JSON as interactive form fields — strings, numbers, booleans, nested objects, arrays

---

## AI Agent System

### AgentShell (24 Commands)

The agent interacts through a single `run_command` tool that dispatches to a Unix-like shell interpreter:

| Category | Commands |
|----------|----------|
| **Navigation** | `ls`, `cd`, `cat`, `head` |
| **Search** | `find`, `grep`, `semantic` |
| **Create** | `touch` (items, tasks, projects, people, edges) |
| **Update** | `echo` (JSON update, markdown write, `>>` append) |
| **Delete** | `rm` (soft-delete items, permanent delete tasks/edges) |
| **Move** | `mv` (inbox ↔ project) |
| **Analysis** | `analyze` (pipeline trigger), `extract` (text), `vision`/`describe` (image) |
| **Calendar** | `cal list`, `cal add` |
| **Export** | `export` (Markdown/JSON for items and projects) |
| **Utility** | `wc`, `history`, `progress`, `cleanup`, `js-eval` |
| **User Interaction** | `ask_user` (`--yes/--no`, `--options`, `--text`), `help` |

### AgentLoop Features

- **3 modes:** Fast (6 iters), Auto (12 iters), Deep (24 iters)
- **Model routing:** Executor model (gpt-5-nano) for quick tasks, Advisor model (gpt-5.5) for complex reasoning
- **5-layer context compression:** Truncate large outputs, prune old messages, deduplicate, auto-summarize, hard truncation
- **Memory auto-injection:** Relevant past learnings injected into system prompt based on context (item type)
- **Document templates:** 7 document types (Meeting Summary, Status Report, Decision Log, Checklist, Research Notes, Comparative Table, Digest)
- **Progress tracking:** `progress` command for step-by-step visual feedback
- **Batch operations:** `find --exec` for processing multiple items with template expansion

### Chat UI Output Channels (18 types)

| Channel | Example |
|---------|---------|
| Text (markdown) | Bold, italic, links |
| Tables | Sortable columns |
| Code blocks | Syntax highlight + copy |
| Bullet/Ordered lists | Native SwiftUI |
| Item cards | Swipeable with Details/Analyze |
| Task cards | Swipeable with Done/Details |
| Document headers | Type icon, summary, section count |
| File links | Tappable navigation to FileBrowser |
| Choice prompts | Numbered buttons |
| Confirmation | Yes/No buttons |
| Free-text input | Multiline text field + submit |
| Progress bar | Step X of Y with color |
| Dashboard grid | 2-column card grid for 4+ cards |
| Project context | Project summary with quick actions |
| Search results | Preview card |
| Analysis accordion | Expandable sections |

---

## Content Pipeline

### Processing Flow

1. **Enqueue** — Item created → `ProcessingQueueService.enqueue()`
2. **Extract** — Text extraction based on type (transcription for audio, OCR+vision for images, bodyText for notes, URL fetch for bookmarks)
3. **Analyze** — Autonomous agent runs with `PipelineTemplate.standard`, producing `analysis.json`
4. **Embed** — `EmbeddingPipelineService.ensureEmbedding()` generates vector embeddings
5. **Index** — `SpotlightIndexService.indexItem()` makes items discoverable via iOS system search
6. **Notify** — Push notification on completion, app badge updated

### Analysis Output

**MeetingAnalysis** (`analysis.json`):
- `shortSummary`, `detailedSummary`
- `decisions` (title, details, confidence)
- `actionItems` (task, owner, dueDate, status)
- `risks` (risk, details, confidence)
- `openQuestions`, `importantDates`, `entities`
- `topicTimeline`

**DynamicAnalysis** (`analysis.dynamic.json`) — Framework-driven, flexible schema

### Cross-Referencing

- `EntityExtractionService` — Extracts entities and creates GraphEdges
- `ProjectIngestionPipeline` — Cross-references items within projects, generates signals
- `GraphIntelligenceService` — Post-ingestion discovers contradictions, patterns, gaps

---

## Capture & Scanning

### Scan Menu (3 options)

| Option | Technology | Output |
|--------|-----------|--------|
| **Scan Document** | VisionKit `VNDocumentCameraViewController` | Multi-page scan → `scan_*.jpg` + OCR |
| **Scan QR/Barcode** | AVFoundation `AVCaptureMetadataOutput` | Continuous code detection with dedup → `note` item + `codes.json` |
| **Live OCR (Real-Time)** | AVFoundation + Vision `VNRecognizeTextRequest` + Core Motion | Streaming text capture with spatial dedup and motion-aware context switching → `note` item |

### QR/Barcode Features
- Supported: QR, Aztec, Code 128, Code 39, Code 93, Data Matrix, EAN-8, EAN-13, ITF-14, PDF417, UPC-E
- Continuous scanning with 3s cooldown dedup
- Haptic feedback on detection
- Tap to open URL, tap to copy text
- Human-readable symbology names

### Live OCR Features
- 5 FPS processing with spatial IOU-based region tracking
- Core Motion integration: stable (reading), panning (scanning), shifting (context break)
- Automatic section separation when camera moves to new document
- Multilingual: en-US, pt-BR, es-ES

---

## iOS Ecosystem Integrations

| Integration | Direction | Status |
|-------------|-----------|--------|
| Calendar read + context sensor | IN | ✅ |
| Calendar create events (agent + UI) | OUT | ✅ |
| Reminders export | OUT | ✅ |
| Share Extension (files, audio, images) | IN | ✅ |
| Format importers (10 formats) | IN | ✅ |
| Export (MD, JSON, SRT, CSV, Graph) | OUT | ✅ |
| Context sensors (7: Calendar, AudioRoute, Location, Focus, Motion, Battery) | IN | ✅ |
| Watch Connectivity | BOTH | ✅ |
| Apple Speech transcription | IN | ✅ |
| Vision OCR document scanner | IN | ✅ |
| Core Spotlight indexing | OUT | ✅ |
| Contacts speaker matching | IN | ✅ |
| Face ID biometric gate | INTERNAL | ✅ |
| Push notifications (pipeline completion) | OUT | ✅ |
| App badge (inbox count) | OUT | ✅ |
| Live Activities | OUT | Implemented, needs real-device test |
| App Intents / Siri | — | Not yet |
| Home screen widgets | — | Not yet |

---

## Security & Privacy

- **API keys** stored in iOS Keychain (Secure Enclave-backed)
- **Face ID** gate for app access (`BiometricGateService`)
- **Audio** stays on device unless AI provider is explicitly configured
- **No backend** — all data is local
- **Provenance tracking** — every field records whether it was modified by `user`, `llm`, `import`, or `system`
- **Manual recursive delete** — no SwiftData cascade deletes; all cleanup is explicit in service layer

---

## Module Layout

```
wawa-note/
  App/                    WawaNoteApp.swift (entry point, ModelContainer, notifications)
  Audio/                  Capture, Playback, Session, FileWriter
  Connectivity/           Watch session, RecordingCoordinator
  ContextCapture/         Calendar, Location, Focus, Motion, Battery, AudioRoute sensors
  Domain/
    Agent/                AgentLoop, AgentTool, ShellInterpreter (24 commands), VFSService, VFSNode, ToolContext
    Calendar/             CalendarEvent, CalendarSyncService, TimelineEntry
    Models/               KnowledgeItem, Project, TaskItem, Person, GraphEdge, Entity, ChatModels, ScannedCode
    Services/             KnowledgeItemService, ProjectService, TaskService, ContentPipelineService, ContentExtractionService,
                          SearchService, ChatService, TrashService, EmbeddingPipelineService, ConfigProjectService, ...
  Ecosystem/
    Export/               ExportService, MarkdownExporter, JSONExporter, ProjectExportService
    Import/               ImportRouter, FormatImporter, 10 importers (ICS, JSON, Markdown, SRT, PDF, HTML, RTF, GitHub Issues)
    Spotlight/            SpotlightIndexService
  LocalIntelligence/      EmbeddingService, SemanticSearchService
  Providers/              AIProvider, OpenAICompatibleProvider, AnthropicProvider, GeminiProvider, ProviderRouter, AIConfigService
  Security/               BiometricGateService
  Storage/                FileArtifactStore, SecureKeyStore
  Transcription/          AppleSpeechTranscriptionEngine, RemoteTranscriptionEngine
  UI/
    Capture/              BarcodeScannerView, BarcodeScannerViewModel, LiveOCRView, LiveOCRViewModel
    Chat/                 ChatView, ChatViewModel, ChatBlockViews
    Components/           ContentView, AudioPlayerView, CreationSheetView, ...
    Files/                FileBrowserView, FileBrowserViewModel, FileRowView, Editors/
    Home/                 HomeView, CaptureViewModel
    Inbox/                InboxView
    Explore/              (inline in ContentView)
    Knowledge/            KnowledgeDetailView, NoteEditorView, JournalEditorView
    Project/              ProjectDetailView, ProjectListView, ProjectTimelineView, ProjectGraphView, ...
    Calendar/             CalendarContainerView, TimelineExplorerView, DayActivityView
    Import/               ImportFormView
    Settings/             SettingsView
  Utilities/              Logging, AppDesign
```

### File Count

- **Swift source files:** ~100+
- **Total lines:** ~50,000+
- **Protocols:** 6 core protocols
- **SwiftData models:** 14 registered types
- **Agent commands:** 24 shell commands
- **Chat UI blocks:** 18 structured output types

---

## Key Design Decisions

1. **VFS as unifying abstraction** — Both user (FileBrowser) and agent (ShellInterpreter) navigate the same virtual filesystem. Paths are human-readable and semantically meaningful.
2. **Single tool, many commands** — The agent has one `run_command` tool that dispatches to 24 sub-commands. This keeps the LLM tool definition compact while providing rich capability.
3. **Dual persistence** — SwiftData for queryable metadata, FileManager for large artifacts. This provides defense in depth and allows direct file manipulation.
4. **Provenance everywhere** — Every graph edge and every field on KnowledgeItem, Project, and TaskItem tracks who modified it and when.
5. **Protocol-first provider abstraction** — AI providers, transcription engines, and format importers are all protocol-conforming, making them testable and swappable.
6. **No backend** — The entire app runs locally. The only network calls are to AI provider APIs (when configured).

---

*Document generated from 35 implementation tasks across the Wawa Note iOS codebase.*
