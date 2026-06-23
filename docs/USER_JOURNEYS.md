# Wawa Note — User Journeys

**Last updated:** 2026-06-22
**Related JIRA:** KAN-8, KAN-9, KAN-10, KAN-11, KAN-34, KAN-48, KAN-49
**Source modules:** All UI/, Domain/Services/, Ecosystem/

---

This document maps the complete user journeys through Wawa Note. Each journey describes the full end-to-end flow, the screens involved, the services orchestrated, and the data produced.

---

## Journey 1: Record a Meeting → Transcript → Analysis → Project

**Primary path.** The core value proposition of Wawa Note.

### Steps

| Step | Screen | Service | Data Created |
|---|---|---|---|
| 1. Open app | ContentView (Capture tab) | — | — |
| 2. Tap record | HomeView → RecordingViewModel | ContextCaptureService fires (6 sensors) | Context annotations stamped |
| 3. Recording in progress | Recording UI with waveform | AudioCaptureService → AudioFileWriter | PCM WAV segments via tap callback |
| 4. Stop recording | Recording UI → stop button | AudioFileWriter.finishRecording() → AudioSegmentConcatenator | `audio.m4a` in `items/<uuid>/` |
| 5. Item created | HomeView (item appears in recent) | KnowledgeItemService.createItem() | KnowledgeItem (type: audio, status: preparingAudio) |
| 6. Status: preparing audio | — | PostRecordingAutomationService (if enabled) | Item transitions: preparingAudio → queuedForTranscription |
| 7. Status: transcribing | Processing queue visible | ContentExtractionService.extractTextFromAudio() → TranscriptionEngine | Apple Speech or Remote Whisper transcription |
| 8. Status: transcribed | Item shows transcript preview | — | `transcript.json` in item directory |
| 9. Status: pending review | Inbox → Needs Review filter | ContentPipelineService marks | Item visible in review queue |
| 10. Manual "Analyze" tap | KnowledgeDetailView → analyze button | ContentPipelineService.process() → AgentLoop | `analysis.json` in item directory |
| 11. AI analysis running | Processing indicator | AgentLoop → pipeline tools (SetTitle, WriteAnalysis, WriteSpeakers) | MeetingAnalysis struct populated |
| 12. Status: analyzed | KnowledgeDetailView shows results | — | Item status = analyzed |
| 13. Assign to project | SendToMenuView → select project | ProjectService.addItem(), ProjectIngestionPipeline.ingest() | Tasks, GraphEdges, Annotations created |
| 14. View in project | ProjectHomeView dashboard | — | Item appears in project timeline, tasks on kanban |

### Key UI screens
- `HomeView.swift` — capture surface with record button
- `RecordingViewModel.swift` — recording state management
- `KnowledgeDetailView.swift` — transcript, analysis, audio player
- `SendToMenuView.swift` — project assignment
- `ProjectHomeView.swift` — project dashboard

### Error paths
- Transcription failure → item status = failed, retry option
- Analysis failure → retry with different provider
- Disk full during recording → forceFinish(), alert user
- Audio route change mid-recording → engine rebuild, automatic recovery

---

## Journey 2: Import a File → Triage → Assign to Project

**Inbound path.** Getting external content into the knowledge workspace.

### Steps

| Step | Screen | Service | Data Created |
|---|---|---|---|
| 1. Tap import | HomeView → file picker button | UIDocumentPickerViewController | Selected file URL |
| 2. Share Extension (alt) | Other app → Share sheet → Wawa Note | ShareViewController | File copied to `group.com.wawa-note/shared/` |
| 3. Format detection | ImportFormView preview | ImportRouter → FormatImporter resolution | Matched importer (10 available) |
| 4. Preview & confirm | ImportFormView (title, type, project) | Importer parses content | Staged KnowledgeItem |
| 5. Import confirmed | — | KnowledgeItemService.createItem() | KnowledgeItem (type: from importer, status: pendingReview) |
| 6. App auto-processes | ContentView.onAppear | ProcessingQueueService | Auto-transcribe if audio, auto-analyze if enabled |
| 7. Inbox triage | InboxView → Needs Review | InboxView filters | Item visible in review queue |
| 8. Review & assign | KnowledgeDetailView → SendToMenuView | ProjectService.addItem() | Item linked to project |

### Supported import formats
| Format | Importer | Extensions |
|---|---|---|
| Plain text | PlainTextImporter | .txt |
| Markdown | MarkdownImporter | .md |
| JSON | JSONImporter | .json |
| PDF | PDFImporter | .pdf |
| HTML | HTMLImporter | .html, .htm |
| RTF | RTFImporter | .rtf |
| SRT subtitles | SRTImporter | .srt |
| ICS calendar | ICSImporter | .ics |
| GitHub Issues | GitHubIssuesImporter | .json (GitHub export) |
| Audio files | AudioImportService | .m4a, .wav, .mp3, .caf |

### Anarlog/Meetily import
| Source | Importer | Notes |
|---|---|---|
| Anarlog format | AnarlogImporter | Watched folder sync via AnarlogSyncService |
| Meetily format | MeetilyImporter | Template mapping via MeetilyTemplateService |

---

## Journey 3: Chat with Agent → Create Tasks and Edges

**Intelligence path.** Conversational interface to the knowledge graph.

### Steps

| Step | Screen | Service | Data Flow |
|---|---|---|---|
| 1. Open chat | ContentView → Chat tab (overlay) | ChatService.findOrCreateConversation() | Loads or creates ChatConversation |
| 2. Set context | ChatView → active project badge | ChatContext (projectID, itemID) | Agent sees project context |
| 3. Type message | ChatView → text input → send | ChatViewModel.sendMessage() | User message appended |
| 4. Agent loop runs | Streaming response | AgentLoop.runStreaming() | LLM with tool access |
| 5. Agent uses tools | Tool execution via ShellInterpreter | ShellTool.run_command → VFS operations | Agent reads/writes filesystem |
| 6. Agent creates tasks | SynthesizeProjectTool / CreateConnectionTool | ProjectService, TaskService, GraphEdgeService | Tasks, edges persisted |
| 7. Rich blocks render | ChatBlockViews | ContentParser → block builder | 18 block types rendered |
| 8. Conversation persists | — | ChatService.appendMessages() | Messages saved to JSON |

### Agent Tools Available in Chat
| Command | Purpose |
|---|---|
| `ls` | List items in inbox or project |
| `cat` | Read item content (transcript, analysis) |
| `find` | Search across items |
| `grep` | Search within item content |
| `analyze` | Trigger AI analysis on item |
| `cal` | Query calendar events |
| `person` | Cross-reference Contacts, Calendar, transcripts |
| `extract` | Extract structured data from text |
| `semantic` | Semantic search across items |
| `progress` | Check processing queue status |
| `export` | Export item or project |

### Chat Block Types Rendered
text, table, code, bulletList, orderedList, projectContext, taskCard, itemCard, searchResults, analysisAccordion, choicePrompt, confirmation, fileLink, documentHeader, freeTextInput, progressUpdate

---

## Journey 4: Scan Document → OCR → Extract Text

**Physical-to-digital path.** Turning paper documents into searchable knowledge.

### Steps

| Step | Screen | Service | Data Created |
|---|---|---|---|
| 1. Tap scan | HomeView → scan button | VNDocumentCameraViewController | Camera viewfinder |
| 2. Capture pages | ScannerView (multi-page) | VisionKit document scanning | Scanned images |
| 3. Review & delete | ScannerView swipe-to-delete | ScannerViewModel | Final page set |
| 4. Save scan | ScannerView → save | KnowledgeItemService.createItem() | KnowledgeItem (type: image, imagePageCount: N) |
| 5. OCR extraction | ContentExtractionService | extractTextFromImage() → Vision | `transcript.json` with OCR text |
| 6. (Alt) Live OCR | LiveOCRView → real-time capture | LiveOCRViewModel + Vision + Core Motion | Continuous text recognition |

---

## Journey 5: Create a Project → Ingest Items → Dashboard

**Organization path.** Building the project workspace.

### Steps

| Step | Screen | Service | Data Created |
|---|---|---|---|
| 1. Create project | ExploreView → + button → CreateProjectSheet | ProjectService.create() | Project (name, slug, color, icon) |
| 2. (Alt) Promote item | Item → PromoteToProjectSheet | ProjectService.create(template:sourceItemIDs:) | Project from item's content |
| 3. Add items | SendToMenuView → assign | ProjectService.addItem() | Item.projectID set |
| 4. Pipeline runs | Background | ProjectIngestionPipeline.ingest() | Tasks extracted, edges created, annotations |
| 5. Health computed | — | ProjectService (healthScore, healthStatus) | Project health metrics |
| 6. Dashboard | ProjectHomeView | All project services | Hero stats, signals, timeline, kanban |

### Project Dashboard Sections
- **HeroStatsCard** — item count, task completion %, health score
- **AttentionRequiredSection** — AgentSuggestion signals (risks, alerts, opportunities)
- **PendingSection** — items waiting for review or triage
- **RecentActivitySection** — latest changes
- **TaskBoard** — kanban columns (To Do / In Progress / Done)
- **Timeline** — chronological view of items and events
- **Graph** — entity relationship visualization
- **People** — person directory
- **Entities** — extracted entities
- **Decisions** — decision log
- **Risk Register** — risk tracking

---

## Journey 6: Provider Setup → First Recording

**Onboarding path.** Getting the AI backend configured.

### Steps

| Step | Screen | Service | Outcome |
|---|---|---|---|
| 1. Open Settings | ContentView → gear icon | — | SettingsView |
| 2. Add provider | ProviderPickerView → + | ProviderTemplates | Template selection |
| 3. Choose template | Provider templates list | — | Pre-filled config for OpenAI/Anthropic/Gemini/LM Studio/Ollama |
| 4. Enter API key | ProviderEditorView → key field | SecureKeyStore.save() | Key stored in Keychain |
| 5. Test connection | "Test" button | ProviderRouter.resolve() → AIProvider.send() | Success/failure feedback |
| 6. Select active | ActiveModelPicker | ActiveProviderManager | Provider set as default |
| 7. (Alt) Auto-discover | LocalProviderScanner | Bonjour + port probe | Ollama/LM Studio/LocalAI found on LAN |
| 8. First recording | Back to Capture tab | Full pipeline runs | AI-powered analysis with configured provider |

### Provider Infrastructure Behind the Scenes
- **ProviderRouter** — factory: config → provider instance
- **BudgetTracker** — daily spending limits
- **MetricsTracker** — latency, TTFT, tokens/second
- **CircuitBreaker** — failure threshold with recovery
- **NetworkMonitor** — NWPathMonitor for connectivity
- **ModelCache** — 1-hour TTL for model lists

---

## Journey 7: Search → Find → Act

**Discovery path.** Finding and acting on existing knowledge.

### Steps

| Step | Screen | Service | Outcome |
|---|---|---|---|
| 1. Open Inbox | InboxView | SearchService | All items or filtered view |
| 2. Filter | Filter picker (Needs Review, All, Unassigned, Flagged, Trash) | InboxView filters | Filtered list |
| 3. Search query | Search bar → type query | SearchService.searchNow() | Results across title, bodyText, transcript, analysis |
| 4. Tap result | KnowledgeDetailView | — | Full item view |
| 5. Action on item | Detail actions | Edit, assign, flag, trash, export | State changes |

---

## Journey 8: Anarlog Sync → Import → Triage

**External sync path.** Watching folders for automated import.

### Steps

| Step | Screen | Service | Outcome |
|---|---|---|---|
| 1. Configure sync | Settings → AnarlogSyncSettingsView | AnarlogSyncService | Watched folder bookmark saved |
| 2. File appears in folder | External (Finder/Files app) | AnarlogSyncService detects | File queued for import |
| 3. Anarlog parsing | Background | AnarlogImporter | AnarlogDocument created |
| 4. Quality validation | — | EvalSystem | Validation gate passed/failed |
| 5. Speaker labeling | — | SpeakerLabeler | Speaker identities resolved |
| 6. STT adapter | — | STTAdapters | Transcript format normalized |
| 7. Import to Wawa Note | — | KnowledgeItemService.createItem() | Item in Inbox → Needs Review |
| 8. Triage | InboxView | — | Normal triage flow |

---

## Cross-Cutting User Journeys

### Trash & Recovery
1. Item → swipe delete → TrashService.moveToTrash() → appears in Trash filter
2. Trash filter → swipe restore → TrashService.restoreFromTrash() → back to Inbox
3. Trash filter → Empty Trash → confirmation → TrashService.emptyTrash() → permanent delete

### Export
1. Item/Project → export action → ProjectExportActions → pick format
2. Formats: Markdown, JSON, SRT, CSV, Graph JSON
3. Project export includes: items, tasks, edges, people, entities, annotations
4. Reminders export: TaskRemindersService → EKReminder in Reminders app
5. Calendar export: CalendarSyncService.createEvent() → EKEvent in Calendar app
