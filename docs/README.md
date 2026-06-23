# Wawa Note — Documentation Index

**Last rebuilt:** 2026-06-22
**Purpose:** Single source of truth for all project documentation. Every doc listed with freshness date, one-line summary, and cross-references to JIRA issues and source modules.

---

## Quick Navigation

| Section | Purpose |
|---|---|
| [Source of Truth](#source-of-truth) | Authoritative documents — read these first |
| [Architecture & Design](#architecture--design) | System design, ADRs, module maps |
| [Feature Specifications](#feature-specifications) | Per-feature specs and user journeys |
| [Technical Specifications](#technical-specifications) | Deep dives into subsystems |
| [Plans & Roadmaps](#plans--roadmaps) | Implementation plans, roadmaps, audits |
| [Operations](#operations) | Build, deploy, test, release |
| [Audits & Reviews](#audits--reviews) | Code reviews, expert panels, import audits |
| [Brand & Design](#brand--design) | Visual identity, UI patterns, design system |
| [TODO Lists](#todo-lists) | Cumulative and per-topic task lists |
| [History (Archived)](#history-archived) | Superseded MVP-era documents |

---

## Source of Truth

Documents that define the project. Read these before making architecture decisions.

| Document | Updated | Summary | Related JIRA | Source Modules |
|---|---|---|---|---|
| [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) | 2026-06-07 | Comprehensive project description — every feature, model, service, and integration | KAN-8, KAN-9, KAN-10, KAN-11 | All |
| [deep-research-report.md](deep-research-report.md) | 2026-05-26 | Strategic direction, competitive analysis, target architecture | — | — |
| [IMPLEMENTATION_PLAN_V2.md](IMPLEMENTATION_PLAN_V2.md) | 2026-06-11 | 5-wave implementation roadmap (Portuguese) | KAN-34, KAN-73, KAN-75 | All |
| [APPLE_TECH_INVENTORY.md](APPLE_TECH_INVENTORY.md) | 2026-05-25 | Apple/iOS technical constraints for iPhone 14 Plus | — | Audio, Connectivity, Ecosystem |
| [API_PROVIDER_CONTRACTS.md](API_PROVIDER_CONTRACTS.md) | 2026-05-30 | Provider and transcription engine abstractions | KAN-42 | Providers, Transcription |
| [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md) | (early) | Security principles, permissions, privacy modes | — | Security, Storage |
| [CODING_STANDARDS.md](CODING_STANDARDS.md) | (early) | Coding conventions and rules | — | All |
| [DECISIONS.md](DECISIONS.md) | 2026-05-30 | 12 Architecture Decision Records (ADRs) | KAN-56, KAN-57, KAN-58, KAN-60 | Domain, Storage |
| [CLAUDE.md](../CLAUDE.md) | 2026-06-12 | Dev workflow, module layout, architectural rules | All | All |
| [DOCUMENTATION_GAP_ANALYSIS.md](DOCUMENTATION_GAP_ANALYSIS.md) | 2026-06-22 | **THIS DOC** — feature × docs × JIRA coverage matrix | — | All |

---

## Architecture & Design

| Document | Updated | Summary | Related JIRA |
|---|---|---|---|
| [DECISIONS.md](DECISIONS.md) | 2026-05-30 | Architecture Decision Records (ADR-0001 through ADR-0012) | KAN-56, KAN-57, KAN-58, KAN-60 |
| [Interface Frameworks for Wawa-note.md](Interface%20Frameworks%20for%20Wawa-note.md) | 2026-05-29 | Navigation pivot justification: 4-tab layout (Capture/Inbox/Explore/Chat) | — |
| [Padroes de interface de mercados especializados para o Wawa-note.md](Padroes%20de%20interface%20de%20mercados%20especializados%20para%20o%20Wawa-note.md) | (early) | UI patterns research from specialized markets | — |
| [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md) | (early) | Data migration flags and procedures | KAN-57, KAN-58 |
| [DOCUMENTATION_GAP_ANALYSIS.md](DOCUMENTATION_GAP_ANALYSIS.md) | 2026-06-22 | Feature × docs × JIRA coverage matrix — what's documented, what's missing | All |

---

## Feature Specifications

| Document | Updated | Summary | Related JIRA | Feature |
|---|---|---|---|---|
| [provider_onboarding_redesign.md](provider_onboarding_redesign.md) | 2026-05-26 | Provider UX redesign: 5-specialist panel, pre-configured templates, progressive disclosure | KAN-42 | AI Provider onboarding |
| [ON_DEVICE_LLM_PLAN.md](ON_DEVICE_LLM_PLAN.md) | 2026-05-27 | Plan for local LLM inference (llama.cpp + ModelDownloadService) | — | On-device LLM |
| [PROMPTS.md](PROMPTS.md) | (early) | AI prompt templates for meeting analysis | KAN-76 | Content pipeline |
| [app-store-metadata.md](app-store-metadata.md) | (early) | App Store listing text | — | App Store |
| [privacy-nutrition-labels.md](privacy-nutrition-labels.md) | (early) | Apple privacy label mappings | — | Privacy |

### Missing Feature Specs (to be created)

| Feature | Priority | Source Files |
|---|---|---|
| Barcode/QR scanning (13 symbologies) | P1 | `UI/Home/BarcodeScannerView.swift`, `BarcodeScannerViewModel.swift` |
| Live OCR (real-time Vision text + Core Motion) | P1 | `UI/Home/LiveOCRView.swift`, `LiveOCRViewModel.swift` |
| Agent memory system (AgentMemoryStore) | P1 | `Domain/Agent/AgentMemoryStore.swift` |
| Lens system (5 built-in lenses) | P2 | `Domain/Services/LensAnalysisService.swift`, `ai_config.json` |
| Anarlog sync ecosystem (15 files) | P2 | `Ecosystem/Anarlog/` |
| TrashService (soft-delete with empty) | P1 | `Domain/Services/TrashService.swift` |
| ConfigProjectService (system config via VFS) | P2 | `Domain/Services/ConfigProjectService.swift` |
| PostRecording automation | P1 | `Domain/Services/PostRecordingAutomationService.swift` |
| Project frameworks (LLM-defined schemas) | P2 | `Domain/Services/FrameworkService.swift` |

---

## Technical Specifications

| Document | Updated | Summary | Related JIRA |
|---|---|---|---|
| [AGENT_SYSTEM_ARCHITECTURE.md](AGENT_SYSTEM_ARCHITECTURE.md) | 2026-06-22 | AgentLoop, ShellInterpreter (24 commands), VFSService (15 paths), AgentMemoryStore, PromptStore, ToolContext | KAN-190 |
| [CHAT_BLOCK_RENDERING.md](CHAT_BLOCK_RENDERING.md) | 2026-06-22 | 18 chat output types with streaming, ContentParser, JSON schemas, how to add new blocks | KAN-192 |
| [CONTENT_PIPELINE.md](CONTENT_PIPELINE.md) | 2026-06-22 | 11-state machine, 8 framework templates, Phase 0/1, recovery, error codes | KAN-199 |
| [PROVIDER_ROUTING.md](PROVIDER_ROUTING.md) | 2026-06-22 | ProviderRouter, BudgetTracker, MetricsTracker, CircuitBreaker, NetworkMonitor, LocalProviderScanner | KAN-202 |

### Missing Technical Specs (to be created)

| Spec | Priority | Complexity | Source Files |
|---|---|---|---|
| Audio capture engine (PCM WAV, crash recovery, route changes) | P1 | Medium | `Audio/AudioCaptureService.swift`, `AudioFileWriter.swift` |
| Project framework system (flexible schemas, DynamicAnalysis) | P2 | High | `Domain/Services/FrameworkService.swift` |
| File storage architecture (FileArtifactStore, layout, recovery) | P1 | Medium | `Storage/FileArtifactStore.swift` |

---

## User Journeys

| Document | Updated | Summary | Related JIRA |
|---|---|---|---|
| [USER_JOURNEYS.md](USER_JOURNEYS.md) | 2026-06-22 | 8 complete user journeys: record→analyze, import→triage, chat→tasks, scan→OCR, create project, provider setup, search, Anarlog sync | KAN-204 |

---

## Plans & Roadmaps

| Document | Updated | Summary | Status |
|---|---|---|---|
| [IMPLEMENTATION_PLAN_V2.md](IMPLEMENTATION_PLAN_V2.md) | 2026-06-11 | 5-wave roadmap with task breakdown | Active (Wave 1-2 in progress) |
| [ON_DEVICE_LLM_PLAN.md](ON_DEVICE_LLM_PLAN.md) | 2026-05-27 | On-device LLM inference plan | Deferred |
| [provider_onboarding_redesign.md](provider_onboarding_redesign.md) | 2026-05-26 | Provider UX redesign plan | Ready for implementation |

### Superpowers Plans (in `docs/superpowers/`)

| Document | Updated | Summary |
|---|---|---|
| [2026-06-17-project-redesign-plan.md](superpowers/2026-06-17-project-redesign-plan.md) | 2026-06-17 | Project dashboard redesign plan |
| [2026-06-19-smarter-analysis-agent.md](superpowers/2026-06-19-smarter-analysis-agent.md) | 2026-06-19 | Smarter analysis agent plan |
| [2026-06-21-project-creation-update-journeys.md](superpowers/2026-06-21-project-creation-update-journeys.md) | 2026-06-21 | Project creation and update journeys |
| [2026-06-21-project-workflow-complete-cycle.md](superpowers/2026-06-21-project-workflow-complete-cycle.md) | 2026-06-21 | Complete project workflow cycle |
| [2026-06-21-project-dashboard-onboarding-navigation.md](superpowers/2026-06-21-project-dashboard-onboarding-navigation.md) | 2026-06-21 | Dashboard, onboarding, navigation |
| [2026-06-16-ai-services-redesign.md](superpowers/2026-06-16-ai-services-redesign.md) | 2026-06-16 | AI services redesign plan |

### Memory Files (in `~/.claude/projects/.../memory/`)

These are point-in-time plans and audits — they capture intent, not documentation state. See `MEMORY.md` for the index.

---

## Operations

| Document | Updated | Summary |
|---|---|---|
| [CLAUDE_WORKFLOW.md](CLAUDE_WORKFLOW.md) | (early) | Claude Code operational workflow |
| [VALIDATION_CHECKLIST.md](VALIDATION_CHECKLIST.md) | 2026-05-27 | iPhone 14 Plus validation checklist |
| [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md) | (early) | Data migration procedures |
| CLAUDE.md §"Dev workflow" | 2026-06-12 | Build/deploy/test commands (`make all`, `make logs`, etc.) |

---

## Audits & Reviews

| Document | Updated | Summary | Related JIRA |
|---|---|---|---|
| [expert_panel_review.md](expert_panel_review.md) | 2026-05-26 | 6-expert panel: onboarding, provider UX, audio, meeting UX, AI, security | KAN-42, KAN-73 |
| [CODE_REVIEW.md](CODE_REVIEW.md) | 2026-06-10 | Copilot code review — 40 findings across 570 lines | — |
| [wawa_note_import_audit.md](wawa_note_import_audit.md) | (early) | Import pipeline architecture review — 1206 lines | — |
| [kiro-review.md](kiro-review.md) | 2026-06-11 | Self-review: code quality and testing gaps | KAN-68, KAN-69 |
| [MASTER_TODO.md](MASTER_TODO.md) | 2026-06-12 | Consolidated todo from 47-perspective audit — 266 lines | All |
| [DOCUMENTATION_GAP_ANALYSIS.md](DOCUMENTATION_GAP_ANALYSIS.md) | 2026-06-22 | Feature × docs × JIRA coverage matrix | All |

---

## Brand & Design

| Document | Updated | Summary |
|---|---|---|
| [wawa_note_brand_design_guide.md](wawa_note_brand_design_guide.md) | (early) | Brand identity, typography, colors, logo concept — 816 lines |
| [Interface Frameworks for Wawa-note.md](Interface%20Frameworks%20for%20Wawa-note.md) | 2026-05-29 | Navigation pivot design rationale |
| [Padroes de interface de mercados especializados para o Wawa-note.md](Padroes%20de%20interface%20de%20mercados%20especializados%20para%20o%20Wawa-note.md) | (early) | UI patterns from specialized market apps |

---

## TODO Lists

Cumulative task lists tracking known issues and improvements.

| Document | Progress | Focus Area | Related JIRA |
|---|---|---|---|
| [TODO_CUMULATIVE.md](TODO_CUMULATIVE.md) | 114 items | Cross-cutting P0/P1/P2 issues | All |
| [TODO_CHAT_AGENT.md](TODO_CHAT_AGENT.md) | 76/100 | Agent and chat system | KAN-9, KAN-46, KAN-82 |
| [TODO_AI_PROVIDERS.md](TODO_AI_PROVIDERS.md) | 15/16 | AI provider infrastructure | KAN-42 |
| [TODO_FILE_MANAGEMENT.md](TODO_FILE_MANAGEMENT.md) | 28/100 | File storage, integrity, recovery | — |
| [TODO_AUDIO_CAPTURE.md](TODO_AUDIO_CAPTURE.md) | (varies) | Audio capture pipeline | KAN-73, KAN-79 |
| [MASTER_TODO.md](MASTER_TODO.md) | 266 lines | Consolidated from 47-perspective audit | All |

---

## History (Archived)

Documents from the meeting-recorder MVP era. All superseded by current architecture. See `history/README.md` for the archive index.

| Document | Summary |
|---|---|
| `history/ARCHITECTURE.md` | MVP-era architecture (superseded) |
| `history/DATA_MODEL.md` | MVP-era data model (superseded) |
| `history/PROJECT_SPEC.md` | MVP-era project spec (superseded) |
| `history/IMPLEMENTATION_PLAN.md` | MVP-era implementation plan (superseded) |
| `history/TASKS.md` | MVP-era task list (superseded) |
| `history/TEST_PLAN.md` | MVP-era test plan (superseded) |
| `history/SESSION_LOG.md` | MVP-era session log (superseded) |
| `history/ux_ui_manual_ai_meeting_companion.md` | MVP-era UX manual (superseded) |
| `history/wawa_note_ios_phase_audit.md` | MVP-era phase audit (superseded) |

### Deprecated

| Document | Superseded By |
|---|---|
| `deprecated/TRANSFORMATION_PLAN.md` | `IMPLEMENTATION_PLAN_V2.md` |

---

## JIRA → Documentation Mapping

| JIRA Key | Title | Status | Related Docs | Source Modules |
|---|---|---|---|---|
| KAN-8 | Project detail + task board UI | To Do | PROJECT_OVERVIEW.md, superpowers/ plans | UI/Project/ |
| KAN-9 | Agentic chat with tool calling | To Do | CLAUDE.md, PROJECT_OVERVIEW.md | UI/Chat/, Domain/Agent/ |
| KAN-10 | Navigation restructure (4 tabs) | To Do | CLAUDE.md, Interface Frameworks | UI/Components/ |
| KAN-11 | Knowledge detail view + connections feed | To Do | CLAUDE.md, PROJECT_OVERVIEW.md | UI/Knowledge/ |
| KAN-13 | Quality, Testing & DevOps | To Do | TEST_PLAN.md, kiro-review.md | Tests/ |
| KAN-34 | Project creation & promote-from-item | Done ✅ | PROJECT_OVERVIEW.md, superpowers/ plans | Domain/Services/ProjectService |
| KAN-42 | Provider management settings | To Do | API_PROVIDER_CONTRACTS.md, provider_onboarding_redesign.md | UI/Settings/, Providers/ |
| KAN-46 | Chat streaming UI + agent tools | To Do | PROJECT_OVERVIEW.md | UI/Chat/ |
| KAN-48 | Capture tab refactor | To Do | PROJECT_OVERVIEW.md | UI/Home/ |
| KAN-49 | Inbox filters + search | To Do | PROJECT_OVERVIEW.md | UI/Inbox/ |
| KAN-54 | Calendar timeline + integration | To Do | CLAUDE.md, PROJECT_OVERVIEW.md | UI/Calendar/, ContextCapture/ |
| KAN-56 | Service protocol abstractions + DI container | Done ✅ | DECISIONS.md | Domain/Protocols/ |
| KAN-57 | Safe store recovery (backup before destroy) | Done ✅ | DECISIONS.md, MIGRATION_GUIDE.md | Storage/ |
| KAN-58 | Migration registry with plist tracking | Done ✅ | DECISIONS.md, MIGRATION_GUIDE.md | Storage/ |
| KAN-60 | AsyncSemaphore + BackgroundWorker | Done ✅ | DECISIONS.md | Domain/Services/ |
| KAN-68 | Unit test infrastructure with mocks | Done ✅ | CODE_REVIEW.md | Tests/ |
| KAN-69 | Integration tests for pipeline flows | To Do | TEST_PLAN.md | Tests/ |
| KAN-73 | AAC M4A causes 40-90s gaps in SFSpeechRecognizer | Done ✅ | TODO_AUDIO_CAPTURE.md | Audio/, Transcription/ |
| KAN-75 | ProjectIngestionPipeline has no deduplication | Done ✅ | — | Domain/Services/ProjectIngestionPipeline |
| KAN-76 | WriteAnalysisTool persists partial JSON without rollback | To Do | PROMPTS.md | Domain/Agent/Tools/ |
| KAN-79 | AudioChunker should produce PCM WAV directly | Done ✅ | TODO_AUDIO_CAPTURE.md | Audio/AudioChunker |
| KAN-118 | Unit tests: ShellInterpreter tokenizer edge cases | To Do | — | Domain/Agent/ShellInterpreter |
| KAN-119 | Unit tests: ContentPipelineService double-resume prevention | To Do | — | Tests/IngestionPipelineTests |
| KAN-120 | Unit tests: AgentLoop tool dispatch cycle | To Do | — | Tests/ |
| KAN-121 | Integration test: full pipeline (record → transcribe → ...) | To Do | — | Tests/ |
| KAN-124 | Siri Shortcuts integration | To Do | CLAUDE.md | Not implemented |
| KAN-125 | Home Screen Widgets (WidgetKit) | To Do | CLAUDE.md | Not implemented |
| KAN-126 | Live Activities / Dynamic Island for recording | To Do | CLAUDE.md | Connectivity/ |
| KAN-127 | Background processing with BGTaskScheduler | To Do | CLAUDE.md | Domain/Services/BackgroundWorker |
| KAN-128 | AirDrop sharing of projects/items | To Do | CLAUDE.md | Not implemented |
| KAN-129 | Handoff between devices | To Do | CLAUDE.md | Not implemented |
| KAN-130 | 2-week dogfooding protocol | To Do | — | — |
| KAN-164 | Project Intelligence - Consolidated Analysis | To Do | — | Domain/Services/ |
| KAN-165 | Incremental persistent failure-tolerant item analysis pipeline | To Do | CLAUDE.md §"What's still in progress" | Domain/Services/ContentPipelineService |
| KAN-166 | File visibility layer | To Do | — | Storage/, UI/ |

---

## File Count Summary

| Category | Count | Path |
|---|---|---|
| Source-of-truth docs | 10 | `docs/*.md` (root-level authoritative) |
| Architecture docs | 5 | `docs/*.md` |
| Feature specs | 5 | `docs/*.md` |
| Technical specs | 0 | *(none yet)* |
| User journeys | 0 | *(none yet)* |
| Plans & roadmaps | 9 | `docs/*.md` + `docs/superpowers/` |
| Operations guides | 4 | `docs/*.md` + `../CLAUDE.md` |
| Audits & reviews | 6 | `docs/*.md` |
| Brand & design | 3 | `docs/*.md` |
| TODO lists | 6 | `docs/*.md` |
| Archived (history) | 9 | `docs/history/` |
| Deprecated | 1 | `docs/deprecated/` |
| **Total** | **58** | |

---

## Conventions

- **Freshness dates** on every document: `**Last updated:** YYYY-MM-DD`
- **JIRA references** in document headers: `**Related JIRA:** KAN-XX, KAN-YY`
- **Source module references:** `**Source:** Domain/Services/ProjectService.swift`
- New features MUST update this index AND add JIRA references
- Stale documents (>30 days) should be reviewed or archived
- This README is rebuilt on every documentation iteration
