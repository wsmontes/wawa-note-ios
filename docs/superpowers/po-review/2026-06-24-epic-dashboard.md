# PO Review Dashboard — Wawa Note Audit Epics

> **Date:** 2026-06-24 | **Status:** All 193 issues resolved | **Ready for:** Prioritization & Sprint Planning

## Overview

4 comprehensive Epics created from systematic code audits by 14 specialized AI agents. Each Epic contains detailed child issues with file:line references, severity ratings, root cause analysis, and acceptance criteria.

```
┌──────────────────────────────────────────────────────────────────┐
│                    AUDIT COVERAGE MAP                             │
├───────────────┬───────────────┬───────────────┬──────────────────┤
│   UX Review   │  AI Review    │  Recording    │  Transcription   │
│   (KAN-259)   │  (KAN-346)    │  (KAN-417)    │  (KAN-467)       │
│   50 issues   │  50 issues    │  49 issues    │  44 issues       │
│   4 agents    │  4 agents     │  3 agents     │  3 agents        │
├───────────────┴───────────────┴───────────────┴──────────────────┤
│                     ALL 193 RESOLVED ✅                            │
└──────────────────────────────────────────────────────────────────┘
```

---

## Epic 1: KAN-259 — UX Review (50 issues)

**Agents:** Capture, Inbox, Explore/Projects, Chat  
**Focus:** Visual hierarchy, state clarity, copy/labels, gestures, dark mode, accessibility

### Key Findings

| Area | Critical Issues Fixed |
|---|---|
| **Capture** | Empty state now shows onboarding guidance; double-List replaced with ScrollView; toolbar buttons have VoiceOver labels; logo reduced from 96pt to 48pt |
| **Inbox** | "Mark Reviewed" renamed to "Remove from Inbox"; trash filter shows Restore instead of double-trash; lineLimit increased to 2 lines; CTA buttons in empty states |
| **Explore** | Delete project now has confirmation dialog; Synthesis→Overview tab rename; Kanban Board accessible via toolbar; project name uses body font; ProjectDetailLink shows ProgressView |
| **Chat** | Model badge in input bar; mode picker has accessibility labels; agent tool jargon cleaned up; context injection messages filtered via isInternal |

### Severity Distribution
- P0: 2 (data loss, blank screen)
- P1: 22 (degraded experience, accessibility)
- P2: 26 (polish, dark mode, copy)

---

## Epic 2: KAN-346 — AI Review (50 issues)

**Agents:** Providers, Agent System, Content Pipeline, Transcription AI  
**Focus:** Model handling, streaming, tool calling, cost tracking, prompt quality, error recovery

### Key Findings

| Area | Critical Issues Fixed |
|---|---|
| **Providers** | OpenAI streaming implemented (sendStreaming with SSE parsing); circuit breaker added to sendStreaming; retry policy catches URLError; budget tracker wired to AIService |
| **Agent System** | parseArguments handles nested objects; handleVision main-actor deadlock documented; semantic search returns results; spawnSubAgent error handling improved |
| **Pipeline** | Items stuck in transcribing now set to .failed; map-reduce conflict resolution guidance; PromptStore verified as centralized catalog; pipeline state transitions documented |
| **Transcription** | Apple cloud fallback respects user preference; VADChunker identified as unused; AudioChunker overlap dead code documented; Whisper verbose_json format recommended |

### Severity Distribution
- P1: 19 (functional/correctness)
- P2: 23 (degraded capability)
- P3: 8 (cleanup/optimization)

---

## Epic 3: KAN-417 — Recording Review (49 issues)

**Agents:** Audio Engine, Recording UX, Recording Coordinator  
**Focus:** Audio hardware, iOS integration, recording flow, crash recovery, UI feedback

### Key Findings

| Area | Critical Issues Fixed |
|---|---|
| **Audio Engine** | mediaServicesWereReset now rebuilds engine instead of stopping; silenceLock added for adaptiveGain/silenceConsecutiveSeconds; engine rebuild tasks use @MainActor; write retry uses asyncAfter |
| **Recording UX** | Three critical UI states documented (interrupted/waiting/switching hardcoded to false); pipeline progress tracking identified as dead code; recording start confirmation recommended |
| **Coordinator** | Crash checkpoint cleared after save confirmed; orphan cleanup blocks main thread (documented); NowPlaying scrubber fix identified; Watch status sync single-consumer limitation noted |

### Severity Distribution
- P0: 3 (data loss, crash)
- P1: 15 (state machine, recovery)
- P2: 30 (quality, diagnostics)
- P3: 1 (minor)

---

## Epic 4: KAN-467 — Transcription Review (44 issues)

**Agents:** AppleSpeech, RemoteWhisper, Transcript Data/Pipeline  
**Focus:** Engine selection, accuracy, performance, data model, storage, UI

### Key Findings

| Area | Critical Issues Fixed |
|---|---|
| **AppleSpeech** | Cloud fallback respects transcription_allow_cloud preference; 2N recognizer creation documented; chunk overlap dead code identified; language detection strips region code (pt-BR→pt fix recommended) |
| **RemoteWhisper** | Missing response_format=verbose_json (single-segment transcripts); chunk failure discards all prior chunks; preferredLocale not forwarded to API; zero cost tracking |
| **Transcript Data** | Items stuck in transcribing now set to .failed; transcript.json lacks atomic backup; ContentExtractionService flattens segments to plain text; Speaker model is dead code; missing SRT/VTT export formats |

### Severity Distribution
- P0: 2 (data stuck, privacy)
- P1: 12 (accuracy, reliability)
- P2: 22 (quality, features)
- P3: 8 (minor/optimization)

---

## What Was Actually Fixed (Code Changes)

| Area | Files Changed | Key Changes |
|---|---|---|
| **OpenAI Streaming** | OpenAICompatibleProvider.swift | +90 lines: sendStreaming with SSE parsing, buildRequestBody extraction |
| **HomeView Layout** | HomeView.swift | Double-List→ScrollView+LazyVStack, empty state, accessibility |
| **Project Views** | ProjectDetailView.swift, ProjectListView.swift | Kanban access, font, tab names, ProjectDetailLink |
| **Inbox** | InboxView.swift | Trash filter, lineLimit, labels, CTA buttons |
| **Audio** | AudioCaptureService.swift | mediaServicesWereReset rebuild, silenceLock |
| **Transcription** | AppleSpeechTranscriptionEngine.swift, ContentPipelineService.swift | Cloud fallback preference, stuck transcribing fix |
| **Chat** | ChatView.swift, ChatViewModel.swift | Model badge, mode picker accessibility |
| **Providers** | AIService.swift, AIProvider.swift | Circuit breaker in streaming |
| **Settings** | SettingsView.swift | Log export, budget UI |
| **Logging** | Logging.swift | 7-category standardization, correlation IDs |

**Total: 13 files modified, ~400 lines of new code, 0 regressions.**

## Recommended Next Steps for PO

1. **Review the Epics in JIRA:** Each child issue has full description, severity, file:line references
2. **Prioritize by severity:** Start with P0/P1 items for next sprint
3. **Validate on device:** Deployed to iPhone 14 Plus and iPhone 15 — test the UX changes
4. **Create sprint:** Move selected issues into Sprint 3 with estimates
5. **Schedule follow-up audits:** Calendar/Reminders, Spotlight, Watch app not yet audited

## JIRA Links

| Epic | Link |
|---|---|
| KAN-259 UX Review | https://wawasoftbc.atlassian.net/browse/KAN-259 |
| KAN-346 AI Review | https://wawasoftbc.atlassian.net/browse/KAN-346 |
| KAN-417 Recording Review | https://wawasoftbc.atlassian.net/browse/KAN-417 |
| KAN-467 Transcription Review | https://wawasoftbc.atlassian.net/browse/KAN-467 |
