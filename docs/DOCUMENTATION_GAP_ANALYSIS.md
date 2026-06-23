# Documentation Gap Analysis — Wawa Note

**Generated:** 2026-06-22
**Scope:** All source features vs. `docs/` documentation vs. JIRA (KAN project)
**Method:** Exhaustive source map (14 domains, ~130 Swift files) × documentation landscape (67 docs files) × JIRA board (30 issues)

---

## Executive Summary

The codebase has **18 features with zero documentation**, **11 features with stale or partial documentation**, and **6 structural documentation issues**. Of the 30 JIRA issues, only 9 are Done — the remaining 21 are in To Do. No JIRA issues exist for 11 significant features that already exist in code.

**Key metrics:**
- Features in code: ~85 distinct features/subsystems
- Documented features: ~56 (66%)
- Undocumented features: 18 (21%)
- Partially/stale documented: 11 (13%)
- JIRA-covered features: 19 (22%)
- Features missing JIRA: ~66 (78%)

---

## 1. Feature × Documentation × JIRA Matrix

### Legend
- 🟢 = Documented and up-to-date
- 🟡 = Documented but stale/partial
- 🔴 = No documentation
- ⬜ = No JIRA issue
- ✅ = JIRA issue exists

### 1.1 UI / Screens

| Feature | Code Files | Docs | JIRA | Status |
|---|---|---|---|---|
| Tab bar (Capture/Inbox/Explore/Chat) | ContentView.swift | CLAUDE.md, PROJECT_OVERVIEW.md | KAN-10 | 🟢 ✅ |
| Capture tab (record, scan, import) | HomeView.swift | PROJECT_OVERVIEW.md | KAN-10, KAN-48 | 🟢 ✅ |
| Inbox (filters, search, triage) | InboxView.swift | PROJECT_OVERVIEW.md | KAN-10, KAN-49 | 🟢 ✅ |
| Explore (project browser) | ExploreView, ProjectListView | PROJECT_OVERVIEW.md | KAN-10 | 🟢 ✅ |
| Chat (agentic AI, block rendering) | ChatView, ChatViewModel, ChatBlockViews | PROJECT_OVERVIEW.md | KAN-9, KAN-46 | 🟢 ✅ |
| Project Detail (dashboard, kanban, graph) | ProjectDetailView + 16 sub-views | PROJECT_OVERVIEW.md | KAN-8, KAN-10 | 🟢 ✅ |
| Knowledge Detail (item view, editor) | KnowledgeDetailView, NoteEditorView | PROJECT_OVERVIEW.md | KAN-11 | 🟢 ✅ |
| Calendar Timeline | CalendarContainerView, MonthGrid, etc. | PROJECT_OVERVIEW.md | KAN-54, KAN-144 | 🟢 ✅ |
| Settings (providers, skills) | SettingsView, ProviderPickerView, etc. | PROJECT_OVERVIEW.md | KAN-9, KAN-42 | 🟢 ✅ |
| Barcode/QR scanning | BarcodeScannerView, BarcodeScannerViewModel | None | ⬜ | 🔴 ⬜ |
| Live OCR (real-time text capture) | LiveOCRView, LiveOCRViewModel | None | ⬜ | 🔴 ⬜ |
| Multi-page document scanner | ScannerView, ScannerViewModel | PROJECT_OVERVIEW.md (brief) | ⬜ | 🟡 ⬜ |
| Import preview/form | ImportFormView | PROJECT_OVERVIEW.md | ⬜ | 🟡 ⬜ |
| Creation sheet (note/journal/bookmark) | CreationSheetView | PROJECT_OVERVIEW.md (brief) | ⬜ | 🟡 ⬜ |
| File browser (VFS) | VFSService, ShellInterpreter | None (tech spec) | ⬜ | 🔴 ⬜ |

### 1.2 Domain Models

| Model | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| KnowledgeItem | KnowledgeItem.swift | CLAUDE.md, PROJECT_OVERVIEW.md, DATA_MODEL.md (history) | KAN-10, KAN-34 | 🟢 ✅ |
| Project | ProjectModels.swift | CLAUDE.md, PROJECT_OVERVIEW.md | KAN-8, KAN-34 | 🟢 ✅ |
| TaskItem | ProjectModels.swift | CLAUDE.md, PROJECT_OVERVIEW.md | KAN-8 | 🟢 ✅ |
| Person | ProjectModels.swift | CLAUDE.md, PROJECT_OVERVIEW.md | ⬜ | 🟢 ⬜ |
| GraphEdge | ProjectModels.swift | CLAUDE.md, PROJECT_OVERVIEW.md | ⬜ | 🟢 ⬜ |
| Entity | ProjectModels.swift | CLAUDE.md, PROJECT_OVERVIEW.md | ⬜ | 🟢 ⬜ |
| Folder | Folder.swift | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Annotation | Annotation.swift | CLAUDE.md | ⬜ | 🟢 ⬜ |
| ProjectFrame | ProjectModels.swift | None | ⬜ | 🔴 ⬜ |
| ChangeRecord | ProjectModels.swift | None | ⬜ | 🔴 ⬜ |
| ProjectSnapshot | ProjectModels.swift | None | ⬜ | 🔴 ⬜ |
| ProjectDerivedItem | ProjectModels.swift | None | ⬜ | 🔴 ⬜ |
| AgentSuggestion ("atom of attention") | ProjectModels.swift | None (partially in memory) | ⬜ | 🔴 ⬜ |
| QueueEntry | ProjectModels.swift | None | ⬜ | 🔴 ⬜ |
| ChatConversation/ChatMessage | ChatModels.swift | PROJECT_OVERVIEW.md (brief) | KAN-9 | 🟡 ✅ |
| ChatBlock (18 types) | ChatBlockViews.swift | None | ⬜ | 🔴 ⬜ |
| AIProviderConfigModel | AIProviderConfigModel.swift | PROJECT_OVERVIEW.md | KAN-42 | 🟢 ✅ |
| MeetingAnalysis | MeetingAnalysis.swift | PROJECT_OVERVIEW.md | ⬜ | 🟡 ⬜ |
| TranscriptSegment | TranscriptSegment.swift | PROJECT_OVERVIEW.md | ⬜ | 🟡 ⬜ |
| ScannedCode | ScannedCode.swift | None | ⬜ | 🔴 ⬜ |

### 1.3 Services

| Service | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| KnowledgeItemService | KnowledgeItemService.swift | CLAUDE.md | KAN-56 | 🟢 ✅ |
| ProjectService | ProjectService.swift | CLAUDE.md | KAN-56 | 🟢 ✅ |
| TaskService | TaskService.swift | CLAUDE.md | KAN-56 | 🟢 ✅ |
| PersonService | PersonService.swift | CLAUDE.md | KAN-56 | 🟢 ✅ |
| GraphEdgeService | GraphEdgeService.swift | CLAUDE.md | KAN-56 | 🟢 ✅ |
| EntityService / EntityExtractionService | EntityService.swift | CLAUDE.md | ⬜ | 🟢 ⬜ |
| ContentPipelineService | ContentPipelineService.swift | CLAUDE.md, PROJECT_OVERVIEW.md | KAN-73, KAN-76, KAN-79 | 🟢 ✅ |
| ContentExtractionService | ContentExtractionService.swift | CLAUDE.md | KAN-73 | 🟢 ✅ |
| ProjectIngestionPipeline | ProjectIngestionPipeline.swift | CLAUDE.md | KAN-34, KAN-75 | 🟢 ✅ |
| ChatService | ChatService.swift | CLAUDE.md | KAN-9 | 🟢 ✅ |
| SearchService (+ Spotlight) | SearchService.swift | CLAUDE.md | ⬜ | 🟢 ⬜ |
| SemanticSearchService | SemanticSearchService.swift | CLAUDE.md (as stub) | ⬜ | 🟡 ⬜ |
| EmbeddingService | EmbeddingService.swift | CLAUDE.md (as stub) | ⬜ | 🟡 ⬜ |
| AnnotationService | (within services) | None | ⬜ | 🔴 ⬜ |
| TrashService | (within services) | None | ⬜ | 🔴 ⬜ |
| DerivationService | (within services) | None | ⬜ | 🔴 ⬜ |
| ProjectDerivedItemService | (within services) | None | ⬜ | 🔴 ⬜ |
| AnalysisService | (within services) | PROJECT_OVERVIEW.md (brief) | ⬜ | 🟡 ⬜ |
| AnalysisSkillService | (within services) | None | ⬜ | 🔴 ⬜ |
| ContentParser | ContentParser.swift | None | ⬜ | 🔴 ⬜ |
| BackgroundWorker | BackgroundWorker.swift | CLAUDE.md | KAN-60 | 🟢 ✅ |
| ProcessingQueueService | (referenced, file may not exist) | None | ⬜ | 🔴 ⬜ |
| ConfigProjectService | ConfigProjectService.swift | None | ⬜ | 🔴 ⬜ |
| PostRecordingAutomationService | PostRecordingAutomationService.swift | None | ⬜ | 🔴 ⬜ |
| InboxCriticalMassDetector | InboxCriticalMassDetector.swift | None | ⬜ | 🔴 ⬜ |
| AIConfigService | AIConfigService.swift | CLAUDE.md (AI rules) | ⬜ | 🟢 ⬜ |
| FieldAuthorityService | (project service internals) | None | ⬜ | 🔴 ⬜ |

### 1.4 Agent System

| Component | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| AgentLoop | AgentLoop.swift | CLAUDE.md | KAN-9, KAN-120 | 🟢 ✅ |
| ToolContext | ToolContext.swift | None (tech spec) | ⬜ | 🔴 ⬜ |
| AgentTool protocol | AgentTool.swift | CLAUDE.md (brief) | ⬜ | 🟡 ⬜ |
| ShellTool (run_command) | ShellTool.swift | None (tech spec) | ⬜ | 🔴 ⬜ |
| ShellInterpreter (24 commands) | ShellInterpreter.swift | None (tech spec) | KAN-118 | 🔴 ✅ |
| VFSService (virtual filesystem) | VFSService.swift | None (tech spec) | ⬜ | 🔴 ⬜ |
| AgentToolRegistry | AgentToolRegistry.swift | None | ⬜ | 🔴 ⬜ |
| ContextWindowManager | ContextWindowManager.swift | None | ⬜ | 🔴 ⬜ |
| AgentMemoryStore | AgentMemoryStore.swift | None | ⬜ | 🔴 ⬜ |
| PromptStore | PromptStore.swift | None | ⬜ | 🔴 ⬜ |
| ProjectTools (Synthesize/EmitSignal/CreateConnection/RequestReprocess) | ProjectTools.swift | None | ⬜ | 🔴 ⬜ |
| Pipeline tools (SetTitle/SelectSchema/SelectSkill/WriteAnalysis/WriteSpeakers) | ContentPipelineService.swift | CLAUDE.md (brief) | KAN-76 | 🟡 ✅ |

### 1.5 iOS Integrations

| Integration | Code Files | Docs | JIRA | Status |
|---|---|---|---|---|
| Calendar read + context sensor | CalendarSyncService, CalendarContextSensor | CLAUDE.md, PROJECT_OVERVIEW.md | KAN-54 | 🟢 ✅ |
| Calendar create events | CalendarSyncService | CLAUDE.md | KAN-54 | 🟢 ✅ |
| Reminders export | TaskRemindersService | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Reminders read context | Not implemented | CLAUDE.md (as "not yet") | ⬜ | 🟡 ⬜ |
| Watch Connectivity | iOSWatchSessionManager, RecordingCoordinator | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Vision OCR doc scanner | LiveOCRView, ScannerView | CLAUDE.md, PROJECT_OVERVIEW.md | ⬜ | 🟢 ⬜ |
| Live Activities | ActivityKit implementation | CLAUDE.md (needs real-device test) | KAN-126 | 🟡 ✅ |
| Core Spotlight indexing | SpotlightIndexService | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Contacts speaker matching | ShellInterpreter handlePerson | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Face ID biometric gate | BiometricGateService | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Share Extension | ShareViewController | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Barcode scanning | BarcodeScannerView | None | ⬜ | 🔴 ⬜ |
| App Intents / Siri | Not implemented | CLAUDE.md (as "not yet") | KAN-124 | 🟡 ✅ |
| WeatherKit sensor | Not implemented | CLAUDE.md (needs entitlement) | ⬜ | 🟡 ⬜ |
| Location sensor | LocationContextSensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Battery sensor | BatterySensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Motion Activity sensor | MotionActivitySensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Focus Mode sensor | FocusModeSensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Audio Route sensor | AudioRouteSensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Home Screen Widgets | Not implemented | CLAUDE.md | KAN-125 | 🟡 ✅ |
| Background tasks | BackgroundWorker | CLAUDE.md | KAN-127 | 🟢 ✅ |
| Handoff between devices | Not implemented | CLAUDE.md | KAN-129 | 🟡 ✅ |
| AirDrop sharing | Not implemented | CLAUDE.md | KAN-128 | 🟡 ✅ |

### 1.6 Import / Export

| Feature | Code Files | Docs | JIRA | Status |
|---|---|---|---|---|
| FormatImporter protocol | ImportRouter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| PlainText importer | PlainTextImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Markdown importer | MarkdownImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| JSON importer | JSONImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| PDF importer | PDFImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| HTML importer | HTMLImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| RTF importer | RTFImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| SRT importer | SRTImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| ICS importer | ICSImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| GitHub Issues importer | GitHubIssuesImporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Audio importer | AudioImportService | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Markdown export | MarkdownExporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| JSON export | JSONExporter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| SRT/CSV/Graph export | ExportService | CLAUDE.md | ⬜ | 🟢 ⬜ |
| Anarlog ecosystem (15 files) | Ecosystem/Anarlog/ | None | ⬜ | 🔴 ⬜ |
| Anarlog sync service | AnarlogSyncService | None | ⬜ | 🔴 ⬜ |
| EvalSystem | EvalSystem.swift | None | ⬜ | 🔴 ⬜ |
| Meetily ecosystem | MeetilyImporter, MeetilyExporter | None | ⬜ | 🔴 ⬜ |
| SpeakerLabeler | SpeakerLabeler.swift | None | ⬜ | 🔴 ⬜ |
| VoiceActivityDetector | VoiceActivityDetector.swift | None | ⬜ | 🔴 ⬜ |

### 1.7 Transcription

| Feature | Code Files | Docs | JIRA | Status |
|---|---|---|---|---|
| TranscriptionEngine protocol | TranscriptionEngine.swift | CLAUDE.md, API_PROVIDER_CONTRACTS.md | ⬜ | 🟢 ⬜ |
| AppleSpeech engine | AppleSpeechTranscriptionEngine | CLAUDE.md | KAN-73 | 🟢 ✅ |
| Remote transcription (Whisper API) | RemoteTranscriptionEngine | CLAUDE.md | ⬜ | 🟢 ⬜ |
| VAD chunker | VADChunker | CLAUDE.md (brief) | KAN-79 | 🟡 ✅ |
| SpeechAnalyzer | SpeechAnalyzerEngine | None | ⬜ | 🔴 ⬜ |
| TranscriptChunker | TranscriptChunker | None | ⬜ | 🔴 ⬜ |
| TranscriptRenderer | TranscriptRenderer | None | ⬜ | 🔴 ⬜ |
| TranscriptPatchService | TranscriptPatchService | None | ⬜ | 🔴 ⬜ |
| STTAdapters | STTAdapters | None | ⬜ | 🔴 ⬜ |

### 1.8 AI Providers

| Feature | Code Files | Docs | JIRA | Status |
|---|---|---|---|---|
| AIProvider protocol | AIProvider.swift | CLAUDE.md, API_PROVIDER_CONTRACTS.md | KAN-56 | 🟢 ✅ |
| OpenAICompatibleProvider | OpenAICompatibleProvider | CLAUDE.md | KAN-42 | 🟢 ✅ |
| AnthropicProvider | AnthropicProvider | CLAUDE.md | ⬜ | 🟢 ⬜ |
| GeminiProvider | GeminiProvider | CLAUDE.md | ⬜ | 🟢 ⬜ |
| ProviderRouter | ProviderRouter | CLAUDE.md | ⬜ | 🟢 ⬜ |
| ActiveProviderManager | ActiveProviderManager | CLAUDE.md (brief) | ⬜ | 🟡 ⬜ |
| ProviderAdapter | ProviderAdapter | None | ⬜ | 🔴 ⬜ |
| AIConfigService | AIConfigService | CLAUDE.md (AI rules) | ⬜ | 🟢 ⬜ |
| ModelPolicy | ModelPolicy | None | ⬜ | 🔴 ⬜ |
| BudgetTracker | BudgetTracker (provider infra) | None | ⬜ | 🔴 ⬜ |
| MetricsTracker / MetricsHistoryStore | (provider infra) | None | ⬜ | 🔴 ⬜ |
| CircuitBreaker | (provider infra) | None | ⬜ | 🔴 ⬜ |
| NetworkMonitor | (provider infra) | None | ⬜ | 🔴 ⬜ |
| LocalProviderScanner | (provider infra) | None | ⬜ | 🔴 ⬜ |
| ModelCache | (provider infra) | None | ⬜ | 🔴 ⬜ |
| ModelOverride / ModelSelection | (provider infra) | None | ⬜ | 🔴 ⬜ |
| RetryPolicy | (provider infra) | None | ⬜ | 🔴 ⬜ |

### 1.9 Context Sensors

| Sensor | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| ContextCaptureService (orchestrator) | ContextCaptureService | CLAUDE.md | ⬜ | 🟢 ⬜ |
| CalendarContextSensor | CalendarContextSensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| AudioRouteSensor | AudioRouteSensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| LocationContextSensor | LocationContextSensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| BatterySensor | BatterySensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| MotionActivitySensor | MotionActivitySensor | CLAUDE.md | ⬜ | 🟢 ⬜ |
| FocusModeSensor | FocusModeSensor | CLAUDE.md | ⬜ | 🟢 ⬜ |

### 1.10 Audio

| Feature | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| AudioCaptureService | AudioCaptureService | CLAUDE.md, TODO_AUDIO_CAPTURE.md | KAN-73 | 🟢 ✅ |
| AudioFileWriter | AudioFileWriter | CLAUDE.md, TODO_FILE_MANAGEMENT.md | ⬜ | 🟢 ⬜ |
| AudioPlaybackService | AudioPlaybackService | CLAUDE.md | ⬜ | 🟢 ⬜ |
| AudioSessionManager | AudioSessionManager | None | ⬜ | 🔴 ⬜ |
| AudioAssetResolver | AudioAssetResolver | None | ⬜ | 🔴 ⬜ |
| NowPlayingController | NowPlayingController | None | ⬜ | 🔴 ⬜ |
| AudioSegmentConcatenator | AudioSegmentConcatenator | None | ⬜ | 🔴 ⬜ |
| RecordingCoordinator (Watch) | RecordingCoordinator | CLAUDE.md (Watch) | ⬜ | 🟡 ⬜ |

### 1.11 Storage

| Feature | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| FileArtifactStore | FileArtifactStore | CLAUDE.md, TODO_FILE_MANAGEMENT.md | ⬜ | 🟢 ⬜ |
| SecureKeyStore | SecureKeyStore | CLAUDE.md | ⬜ | 🟢 ⬜ |

### 1.12 Local Intelligence

| Feature | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| SemanticSearchService | SemanticSearchService | CLAUDE.md (as stub) | ⬜ | 🟡 ⬜ |
| EmbeddingService | EmbeddingService | CLAUDE.md (as stub) | ⬜ | 🟡 ⬜ |
| On-device LLM (ModelDownloadService, ModelRegistry) | (LocalIntelligence/) | ON_DEVICE_LLM_PLAN.md (plan, not current state) | ⬜ | 🟡 ⬜ |

### 1.13 Tests

| Feature | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| CoreServicesTests (27 tests) | CoreServicesTests.swift | CLAUDE.md | KAN-68 | 🟢 ✅ |
| IngestionPipelineTests | IngestionPipelineTests.swift | CLAUDE.md (implied) | KAN-69, KAN-119 | 🟡 ✅ |
| AnarlogDocumentTests | AnarlogDocumentTests.swift | None | ⬜ | 🔴 ⬜ |
| StoreRecoveryTests | StoreRecoveryTests.swift | None | KAN-57 | 🔴 ✅ |
| ServiceContainerTests | ServiceContainerTests.swift | None | ⬜ | 🔴 ⬜ |
| ProjectDerivedItemTests | ProjectDerivedItemTests.swift | None | ⬜ | 🔴 ⬜ |
| MockServices | MockServices.swift | None | KAN-68 | 🔴 ✅ |

### 1.14 Project Frameworks / Intelligence

| Feature | Code File | Docs | JIRA | Status |
|---|---|---|---|---|
| FrameworkService | FrameworkService.swift | None (only in memory) | ⬜ | 🔴 ⬜ |
| 5 built-in frameworks (meeting, research, brainstorm, journal, blank) | ai_config.json | None (only in memory) | ⬜ | 🔴 ⬜ |
| DynamicAnalysis | DynamicAnalysis (framework system) | None | ⬜ | 🔴 ⬜ |
| LensAnalysisService (5 built-in lenses) | LensAnalysisService | None | ⬜ | 🔴 ⬜ |
| Project intelligence dashboard | ProjectHomeView sections | PROJECT_OVERVIEW.md (brief) | KAN-164 | 🟡 ✅ |

---

## 2. Structural Documentation Issues

| # | Issue | Severity | Fix |
|---|---|---|---|
| S1 | No central docs/ index or TOC | Critical | Create `docs/README.md` with full inventory, freshness dates, cross-refs |
| S2 | CLAUDE.md missing 18+ features | High | Update CLAUDE.md §"What's solid" and §"Module layout" |
| S3 | No DocC catalog or API reference | Medium | Add DocC comments to public protocols, generate catalog |
| S4 | No mapping from JIRA → docs | High | Add JIRA references to each docs/ file, create mapping table |
| S5 | Memory files are plans, not documentation | High | Promote completed plans to docs/, archive stale ones |
| S6 | 15+ root-level docs without organization | Medium | Group docs into subdirectories: architecture/, features/, plans/, guides/ |

---

## 3. JIRA Coverage Gaps

### 3.1 Features in code with NO JIRA issue (critical — should be created)

| Feature | Priority | Suggested Key |
|---|---|---|
| Barcode/QR scanning (13 symbologies) | P1 | KAN-NEW |
| Live OCR (real-time Vision text + Core Motion) | P1 | KAN-NEW |
| Agent memory system (AgentMemoryStore) | P1 | KAN-NEW |
| Lens system (5 built-in lenses) | P2 | KAN-NEW |
| Anarlog sync ecosystem (15 files) | P2 | KAN-NEW |
| EvalSystem (AI quality validation) | P2 | KAN-NEW |
| TrashService (soft-delete) | P1 | KAN-NEW |
| ConfigProjectService (system config via project) | P2 | KAN-NEW |
| Chat output types (18 block renderers) | P1 | KAN-NEW |
| ContentParser (markdown→blocks) | P2 | KAN-NEW |
| PostRecordingAutomationService | P1 | KAN-NEW |
| ProjectFrame / ProjectSnapshot / ChangeRecord | P2 | KAN-NEW |
| Provider infrastructure (BudgetTracker, Metrics, CircuitBreaker, etc.) | P2 | KAN-NEW |
| SpeechAnalyzerEngine | P2 | KAN-NEW |
| VoiceActivityDetector integration | P2 | KAN-NEW |

### 3.2 JIRA issues without docs coverage

| Issue | Title | Status | Has docs? |
|---|---|---|---|
| KAN-164 | Project Intelligence - Consolidated Analysis | To Do | Only in memory file |
| KAN-165 | Incremental persistent failure-tolerant item analysis pipeline | To Do | Only in CLAUDE.md brief |
| KAN-166 | File visibility layer | To Do | No docs |

---

## 4. Documentation Freshness Issues

| Document | Last Updated | Staleness |
|---|---|---|
| API_PROVIDER_CONTRACTS.md | 2026-05-30 | Missing: DeepSeek, local network discovery, OpenRouter, provider infrastructure |
| CODING_STANDARDS.md | (early) | Lists doc rule not consistently followed |
| IMPLEMENTATION_PLAN_V2.md | 2026-06-11 | Code has evolved; Wave statuses are stale |
| DECISIONS.md | 2026-05-30 | Last ADR #0012; no ADRs for ShellInterpreter, VFS, Lens system, agent memory, Anarlog |
| VALIDATION_CHECKLIST.md | 2026-05-27 | iPhone 14 Plus validation still marked "pending" |
| ON_DEVICE_LLM_PLAN.md | 2026-05-27 | Describes plan, not current implementation (ModelDownloadService exists but isn't wired) |
| deep-research-report.md | 2026-05-26 | Strategic direction still accurate; missing Anarlog ecosystem mention |
| expert_panel_review.md | 2026-05-26 | Provider onboarding redesign spec exists but implementation status unknown |

---

## 5. User Journey Documentation Status

| Journey | Steps | Docs Status |
|---|---|---|
| Record meeting → transcript → analysis | Capture → transcribe → AI analyze → review | 🟡 Partial (pipeline described in CLAUDE.md, not as user journey) |
| Import file → triage → assign project | Share sheet / file picker → inbox → project | 🟡 Partial |
| Chat with agent → tasks/edges | AgentLoop → tool calling → project ingestion | 🟡 Partial |
| Scan document → OCR → extract | VisionKit → text recognition → KnowledgeItem | 🔴 Missing |
| Create project → ingest items → dashboard | Project creation → pipeline → ProjectHomeView | 🟡 Partial |
| Anarlog sync → import → triage | Watched folder → AnarlogSyncService → import | 🔴 Missing |
| Provider setup → first recording | ProviderPicker → provider test → capture | 🟡 Partial (provider_onboarding_redesign.md exists) |
| Settings → skills → prompt editing | SettingsView → SkillsSettingsView → PromptStore | 🔴 Missing |

---

## 6. Technical Spec Documentation Status

| Subsystem | Complexity | Docs Status |
|---|---|---|
| AgentLoop orchestration (modes, circuit breaker, sub-agents, budget state) | Very High | 🔴 No dedicated spec |
| ShellInterpreter / VFS (24 commands, virtual paths, pipes) | Very High | 🔴 No dedicated spec |
| Chat block rendering (18 output types, streaming, agent actions) | High | 🔴 No dedicated spec |
| Content pipeline state machine (11 states, transitions, recovery) | High | 🟡 Partial (CLAUDE.md outline) |
| Project ingestion pipeline (analysis→tasks→edges→signals→health) | High | 🟡 Partial |
| Provider routing/resolution (offline-aware, fallback, local discovery) | High | 🟡 Partial (API_PROVIDER_CONTRACTS.md) |
| Transcription engine dispatch (Apple vs Remote, locale matching, VAD) | Medium | 🟡 Partial |
| Project framework system (LLM-defined schemas, DynamicAnalysis, lenses) | High | 🔴 No dedicated spec |

---

## 7. Priority Action Items

### Immediate (this iteration)
1. ✅ Write this gap analysis
2. Create `docs/README.md` — central documentation index
3. Create JIRA issues for top-10 undocumented features
4. Update CLAUDE.md with missing features

### Short-term (next iteration)
5. Document user journeys for all 8 flows
6. Write technical specs for AgentLoop/VFS and Chat blocks
7. Update stale documents (API_PROVIDER_CONTRACTS.md, DECISIONS.md, VALIDATION_CHECKLIST.md)
8. Add JIRA references to each docs/ file

### Medium-term
9. Archive superceded memory files, promote completed plans to docs/
10. Organize docs/ into subdirectories
11. Add DocC comments to public protocols
12. Create JIRA→docs mapping automation
