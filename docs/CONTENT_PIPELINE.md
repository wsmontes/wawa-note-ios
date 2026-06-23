# Content Pipeline — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-199, KAN-73, KAN-75, KAN-76, KAN-79, KAN-165
**Source modules:** `Domain/Services/ContentPipelineService.swift`, `ContentExtractionService.swift`, `ProjectIngestionPipeline.swift`

---

## Overview

The content pipeline transforms raw captured content into structured project intelligence. It is the central nervous system of Wawa Note — every KnowledgeItem flows through it from initial capture to final analysis and project ingestion.

---

## State Machine

```
                    ┌──────────┐
                    │  draft   │  ← Item created, no processing yet
                    └────┬─────┘
                         │ startRecording()
                    ┌────▼─────┐
                    │ recording│  ← Audio actively being captured
                    └────┬─────┘
                         │ stopRecording()
                    ┌────▼──────────┐
                    │ preparingAudio │  ← Concatenation, format conversion
                    └────┬──────────┘
                         │ audio ready
                    ┌────▼────────────────┐
                    │ queuedForTranscription│  ← In processing queue
                    └────┬────────────────┘
                         │ dequeued
                    ┌────▼──────────┐
                    │ transcribing  │  ← Apple Speech or Remote Whisper
                    └────┬──────────┘
                         │ transcription complete
                    ┌────▼──────────┐
                    │ transcribed   │  ← Transcript available
                    └────┬──────────┘
                         │ user reviews / auto-analyze
                    ┌────▼──────────┐
                    │ pendingReview │  ← Waiting for user action
                    └────┬──────────┘
                         │ analyze button / auto-analyze
                    ┌────▼──────┐
                    │ analyzing │  ← AI AgentLoop running
                    └────┬──────┘
                         │ analysis complete
                    ┌────▼──────┐
                    │ analyzed  │  ← Final state, ready for project ingestion
                    └───────────┘

    Error states (from any active state):
    draft ──────────────────────────► failed
    recording ──────────────────────► failed  (hardware, disk full)
    preparingAudio ─────────────────► failed  (corrupt file)
    queuedForTranscription ─────────► failed  (queue timeout)
    transcribing ───────────────────► failed  (API error, unsupported format)
    analyzing ──────────────────────► failed  (LLM error, invalid JSON)

    Terminal state:
    any state ──────────────────────► archived (user action)
```

### State transitions table

| From | To | Trigger | Reversible |
|---|---|---|---|
| `draft` | `recording` | User taps record | No |
| `recording` | `preparingAudio` | User stops recording | No |
| `preparingAudio` | `queuedForTranscription` | Audio file ready | No |
| `queuedForTranscription` | `transcribing` | ProcessingQueueService dequeues | No |
| `transcribing` | `transcribed` | TranscriptionEngine returns | No |
| `transcribed` | `pendingReview` | Auto or manual advance | Yes (back to transcribed) |
| `pendingReview` | `analyzing` | User taps analyze / auto-analyze | No |
| `analyzing` | `analyzed` | AgentLoop completes | No |
| `any active` | `failed` | Error detected | Yes (retry → queuedForTranscription) |
| `any` | `archived` | User archives item | Yes (unarchive) |

---

## Pipeline Phases

### Phase 0: Pre-extraction
**Purpose:** Get the best available text from the item, regardless of its source type.

| Item Type | Extraction Method |
|---|---|
| `audio` | Transcribe via Apple Speech or Remote Whisper API |
| `image` | OCR via Vision (VNRecognizeTextRequest) |
| `webBookmark` | Fetch page content, extract body text |
| `note` / `journalEntry` | Use existing `bodyText` directly |
| `meeting` | Transcribe audio attachment |

**Service:** `ContentExtractionService.bestAvailableText(for:)`

**Dispatch logic:**
1. If item has `bodyText` → use it
2. If item has `audioFileRelativePath` → transcribe
3. If item has `imageFileRelativePath` → OCR
4. If item is bookmark → web fetch

### Phase 1: AI Analysis
**Purpose:** Run an AgentLoop on the extracted text to produce structured analysis.

**Service:** `ContentPipelineService.process(_:using:forceReanalysis:extractionOnly:)`

**Agent loop flow:**
1. Load framework template (meeting, research, brainstorm, etc.)
2. Build context window with transcript + framework instructions
3. AgentLoop.runAutonomous() with mode=auto (12 iterations)
4. Agent tools available: SetTitle, SelectSchema, SelectSkill, WriteAnalysis, WriteSpeakers
5. Output: `analysis.json` written to item directory

**Analysis JSON structure:**
```json
{
  "shortSummary": "One-line summary",
  "detailedSummary": "Multi-paragraph summary",
  "decisions": ["Decision 1", "Decision 2"],
  "actionItems": [
    {"description": "Task description", "owner": "Name", "priority": "high"}
  ],
  "risks": ["Risk description"],
  "openQuestions": ["Question?"],
  "importantDates": [{"date": "2026-07-01", "description": "Deadline"}],
  "entities": [{"name": "Entity", "type": "organization"}],
  "sentiment": {"overall": "positive", "confidence": 0.85}
}
```

---

## Framework Templates (8)

Each template provides system prompt instructions tailored to the item type.

| Framework | Use Case | Special Instructions |
|---|---|---|
| `meeting` | Business meetings | Focus on decisions, action items, owners |
| `research` | Research interviews | Focus on insights, evidence, methodology |
| `brainstorm` | Ideation sessions | Focus on ideas, connections, opportunities |
| `journal` | Personal journal entries | Focus on reflections, patterns, growth |
| `coaching` | Coaching sessions | Focus on goals, obstacles, action plans |
| `legal` | Legal discussions | Focus on obligations, dates, risks, parties |
| `product` | Product discussions | Focus on features, priorities, trade-offs |
| `blank` | Generic | No special instructions, pure extraction |

---

## Project Ingestion (Post-Analysis)

After analysis is complete, `ProjectIngestionPipeline.ingest()` transforms analysis into project data.

### Ingestion steps

1. **Task extraction:** Parse `actionItems` → create `TaskItem` records
2. **Edge creation:** Link item to project, link tasks to item (`produced` edge)
3. **Person linking:** Parse `entities` → find-or-create `Person` records
4. **Annotation creation:** Save analysis fields as `Annotation` records
5. **Entity extraction:** `EntityExtractionService` → `Entity` records
6. **Signal generation:** `DerivationService` → `AgentSuggestion` (opportunities, risks)
7. **Health recompute:** Update `Project.healthScore` and `Project.healthStatus`
8. **Synthesis update:** Update `Project.synthesis` if this is the latest analysis

### Deduplication (KAN-75)
- Tasks matched by description + project before creation
- Edges checked for existing (fromID, toID, edgeType) triple
- Annotations use upsert pattern (delete existing, insert new)

---

## Recovery & Resilience

### Checkpoint system
- `analysis.json` written atomically (temp → rename)
- Transcript saved immediately on completion (not in pipeline batch)
- Item status written before each phase transition

### Double-resume prevention (KAN-119)
- ProcessingQueueService checks item status before dequeuing
- If item is already `analyzing` or `analyzed`, skip dequeue
- Idempotency key: (itemID, phase)

### WriteAnalysisTool rollback (KAN-76)
1. Write candidate analysis to `<uuid>/.analysis.tmp.json`
2. Validate JSON structure against schema
3. On success: rename `.analysis.tmp.json` → `analysis.json`
4. On failure: delete temp file, keep previous `analysis.json`
5. If no previous analysis exists, leave item in `pendingReview`

### Interruption recovery
- App backgrounded during analysis → agent loop cancelled → item stays at `pendingReview`
- App terminated during transcription → item stays at `transcribing` → retried on next launch
- Disk full during write → error logged, item transitions to `failed`

---

## Processing Queue (ProcessingQueueService)

Manages the background job queue for transcription and analysis.

| Priority | Item Type | Notes |
|---|---|---|
| 0 | New recordings | Just captured, user waiting |
| 1 | Imported files | From share extension or file picker |
| 2 | Reprocess requests | Marked for re-analysis |
| 3 | Bulk operations | Background catch-up |

**Concurrency:** One transcription at a time (hardware limit), one analysis at a time (API rate limit).

**Status tracking:** `QueueEntry` SwiftData model tracks position, retries, errors.

---

## Integration Points

```
AudioCaptureService.stopRecording()
    → KnowledgeItem.status = .preparingAudio
    → AudioFileWriter.finishRecording()
    → AudioSegmentConcatenator.concatenate()
    → KnowledgeItem.status = .queuedForTranscription

ProcessingQueueService
    → ContentPipelineService.process()
        → ContentExtractionService.bestAvailableText()
            → TranscriptionEngine.transcribeFile() or Vision OCR
        → KnowledgeItem.status = .pendingReview
        → [if auto-analyze enabled]
            → AgentLoop.runAutonomous()
            → WriteAnalysisTool
            → KnowledgeItem.status = .analyzed
            → ProjectIngestionPipeline.ingest()

PostRecordingAutomationService (hooks)
    → On .recordingStopped notification
    → Check AutomationSettings.autoTranscribe → advance to queued
    → Check AutomationSettings.autoAnalyze → advance through to analyzed
```

---

## Error Codes

| Code | Phase | Meaning | Recovery |
|---|---|---|---|
| `TR-001` | Transcribe | Apple Speech unavailable | Retry with Remote engine |
| `TR-002` | Transcribe | Remote Whisper API error | Retry with backoff (3×) |
| `TR-003` | Transcribe | Unsupported audio format | Convert to WAV, retry |
| `AN-001` | Analyze | LLM API error | Retry with fallback provider |
| `AN-002` | Analyze | Invalid JSON output | Retry with stricter prompt |
| `AN-003` | Analyze | Context window exceeded | Chunk transcript, analyze parts |
| `IN-001` | Ingest | Duplicate task detected | Skip, log, continue |
| `FL-001` | Any | Disk full | Alert user, transition to failed |
