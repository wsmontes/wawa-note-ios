# Unified Transcription Pipeline — Design Spec

> **Target:** Replace scattered transcription logic across 8 entry points with a single orchestrator + focused processors.

## Problem

The transcription pipeline has 8 entry points with inconsistent error handling, illegal state transitions, and silent failures. Items get permanently stuck in intermediate states. Errors are invisible to users.

## Architecture

### One orchestrator, five processors

```
TranscriptionPipeline.swift (orchestrator, ~300 lines)
  │
  ├─ ContentProcessor (protocol)
  │   ├─ AudioProcessor (~400 lines)
  │   ├─ ImageProcessor (~200 lines)
  │   └─ TextProcessor (~100 lines)
  │
  ├─ ContentAnalysisService (~500 lines, extracted)
  │
  └─ resolveEngine() (static, already exists)
```

### Single entry point

```
All sources → ProcessingQueue.enqueue() → TranscriptionPipeline.run()
```

```
run(itemID, context, mode)
  │
  ├─ Guard: item exists
  ├─ Guard: dedup (activeJobs)
  │
  ├─ Phase 0: Extract (if mode != .analyzeOnly)
  │   └─ processor.extract(from:)
  │       ├─ ✅ → .transcribed
  │       └─ ❌ → .failed + lastError + return
  │
  ├─ Phase 1: Analyze (if mode == .full)
  │   └─ analysisService.analyze(item:)
  │       ├─ ✅ → .analyzed
  │       └─ ❌ → .failed + lastError
  │
  └─ defer: if !terminalStateReached → .failed + post .pipelineCompleted
```

## ContentProcessor Protocol

```swift
protocol ContentProcessor {
    /// Extracts text from an item. Sets item.status = .failed + lastErrorRaw on failure.
    /// - Returns: extracted text, or nil if extraction failed.
    func extract(from item: KnowledgeItem, context: ModelContext) async -> String?
}
```

## AudioProcessor

Handles all audio types: recordings, imports, chat dictation.

### Validation
- Audio file exists at sandbox or shared path
- File size > 4KB
- Duration >= 1 second
- Duration <= 2 hours (7200s)

### Engine Resolution
- Same logic as existing `ContentExtractionService.resolveEngine()`
- Returns Apple on-device, Apple cloud fallback, or Remote Whisper

### Transcription (via engine)
- Check availability + prepare if needed
- Checkpoint resume: load `transcript_checkpoint.json`, set `resumeFromChunk`
- Engine.transcribeFile(audioURL, meetingId)
- On success: write `transcript.json`, delete checkpoint, set `.transcribed`
- On failure: set `.failed` + `lastErrorRaw`, DO NOT return fallback text

### Safe Re-transcription
- Before transcription: `moveItem` transcript.json → transcript.json.bak
- On success: `removeItem` transcript.json.bak
- On failure: `moveItem` transcript.json.bak → transcript.json (restore)

### Error Cases (17)
| Code | Condition | lastErrorRaw |
|------|-----------|-------------|
| AUDIO-01 | File not found | "Audio file not found. It may have been moved or deleted." |
| AUDIO-02 | File too small (<4KB) | "Audio file is too small (less than 4KB)." |
| AUDIO-03 | Duration too short (<1s) | "Audio is less than 1 second. Record at least a few seconds of speech." |
| AUDIO-04 | Duration too long (>2h) | "Recording exceeds 2-hour maximum. Split into shorter segments." |
| AUDIO-05 | No engine available | "No transcription engine available. Check Settings → AI Services." |
| AUDIO-06 | Permission denied | "Speech recognition permission denied. Enable in Settings → Privacy." |
| AUDIO-07 | Model not installed | "On-device speech model for {locale} not installed. Connect to Wi-Fi." |
| AUDIO-08 | Timeout | "On-device recognition timed out. Try a shorter recording or Whisper API." |
| AUDIO-09 | No internet (Remote) | "No internet connection. Whisper API requires network access." |
| AUDIO-10 | Auth failed (401/403) | "Whisper API authentication failed. Check your API key in Settings." |
| AUDIO-11 | File too large (413) | "Audio too large for Whisper API (max 25 MB). Try a shorter recording." |
| AUDIO-12 | Rate limited (429) | "Whisper API rate limited. Wait a few minutes and try again." |
| AUDIO-13 | Server error (5xx) | "Whisper API server error. The service may be temporarily unavailable." |
| AUDIO-14 | Retries exhausted | "Transcription failed after {N} attempts. Last error: {msg}" |
| AUDIO-15 | Engine error (generic) | "{engine}: {localizedError}" |
| AUDIO-16 | No speech detected | "No speech detected in the audio. Try recording in a quieter environment." |
| AUDIO-17 | Task cancelled | "Transcription was cancelled." |

## ImageProcessor

### Extraction
1. Apple OCR (Vision framework)
2. LLM Vision (provider.send with image)
3. Combine: OCR text + visual description

### Error Cases (4)
| Code | Condition | lastErrorRaw |
|------|-----------|-------------|
| IMG-01 | File unreadable | "Image file could not be read. It may be corrupted." |
| IMG-02 | No text + no vision | "No text or visual content could be extracted from this image." |
| IMG-03 | OCR failed | "Text recognition failed. Try a clearer photo with better lighting." |
| IMG-04 | Task cancelled | "Image processing was cancelled." |

## TextProcessor

### Extraction
- bodyText: return directly if non-empty
- webBookmark: fetch URL content via URLSession, extract plain text
- Imported docs: use existing FormatImporter → bodyText

### Error Cases (3)
| Code | Condition | lastErrorRaw |
|------|-----------|-------------|
| TXT-01 | Empty content | "No text content found in this item." |
| TXT-02 | Bookmark fetch failed | "Could not fetch content from the bookmark URL." |
| TXT-03 | Task cancelled | "Text processing was cancelled." |

## ContentAnalysisService

Extracted from `ContentPipelineService.process()` Phase 1.

### Flow
1. Resolve AI provider via `ProviderRouter.resolveActive()`
2. Get model via `ModelTierResolver.resolveForAnalysis()`
3. Build agent prompt with `SourceContext` (recording, import, scan, note)
4. Run `AgentLoop` with retry (max 2)
5. On success: write `analysis.json`, set `.analyzed`, clear `inboxDate`
6. On failure: set `.failed` + `lastErrorRaw`

### Error Cases (6)
| Code | Condition | lastErrorRaw |
|------|-----------|-------------|
| ANL-01 | No provider | "No AI provider configured. Go to Settings → AI Services." |
| ANL-02 | Auth failed (401/403) | "AI provider authentication failed. Check your API key in Settings." |
| ANL-03 | Rate limited (429) | "AI provider rate limited. Wait and try again." |
| ANL-04 | Server error (5xx) | "AI provider server error. The service may be temporarily unavailable." |
| ANL-05 | Invalid output | "Analysis produced invalid output after retry. The content may be too complex." |
| ANL-06 | Task cancelled | "Analysis was cancelled." |

## TranscriptionPipeline Orchestrator

### Public API
```swift
@MainActor
final class TranscriptionPipeline {
    static let shared = TranscriptionPipeline()
    
    enum Mode {
        case transcribeOnly
        case full
    }
    
    func run(
        itemID: UUID,
        context: ModelContext,
        mode: Mode = .full
    ) async
}
```

### Internal State
```swift
private var activeJobs: [UUID: Task<Void, Never>] = [:]
```

### Implementation (~300 lines)
```swift
func run(itemID: UUID, context: ModelContext, mode: Mode) async {
    // Dedup
    guard activeJobs[itemID] == nil else { return }
    
    let task = Task { @MainActor in
        var terminalStateReached = false
        defer {
            activeJobs[itemID] = nil
            if !terminalStateReached {
                if let item = try? KnowledgeItemService(context: context).fetchItem(id: itemID) {
                    if !item.status.isTerminal {
                        item.lastErrorRaw = "Pipeline terminated without reaching a terminal state."
                        item.status = .failed
                        context.safeSave(context: "pipeline-terminal-guarantee", itemId: itemID)
                    }
                }
            }
            NotificationCenter.default.post(name: .pipelineCompleted, object: itemID.uuidString)
        }
        
        // Fetch item
        guard let item = try? KnowledgeItemService(context: context).fetchItem(id: itemID) else {
            terminalStateReached = true
            return
        }
        
        // Phase 0: Extract
        if mode != .analyzeOnly {
            let processor = resolveProcessor(for: item.type)
            if let text = await processor.extract(from: item, context: context) {
                item.status = .transcribed
            } else {
                terminalStateReached = true  // processor already set .failed
                return
            }
        }
        
        // Phase 1: Analyze
        if mode == .full {
            terminalStateReached = true
            await analysisService.analyze(item: item, context: context)
        } else {
            item.status = .pendingReview
            terminalStateReached = true
        }
    }
    activeJobs[itemID] = task
}

private func resolveProcessor(for type: KnowledgeItemType) -> any ContentProcessor {
    switch type {
    case .audio: return AudioProcessor()
    case .image: return ImageProcessor()
    default: return TextProcessor()
    }
}
```

## Integration Points

### All callers → ProcessingQueue → TranscriptionPipeline
```
RecordingCoordinator.stopRecording()
KnowledgeDetailView.transcribe() / reprocessItem()
ContentView.autoProcessPendingItems()
cleanupOrphanedRecordings()
        │
        ▼
ProcessingQueueService.enqueue(itemID)
        │
        ▼
ContentPipelineService.processEntry(itemID)  ← simplified
        │
        ▼
TranscriptionPipeline.shared.run(itemID, context, mode)
```

### Direct calls (chat dictation, inline processing)
```
ChatView.dictation
KnowledgeDetailView.extraction-only
        │
        ▼
TranscriptionPipeline.shared.run(itemID, context, mode: .transcribeOnly)
```

## What Changes Per File

| File | Action |
|------|--------|
| `TranscriptionPipeline.swift` | **CREATE** — orchestrator |
| `AudioProcessor.swift` | **CREATE** — audio extraction |
| `ImageProcessor.swift` | **CREATE** — image extraction |
| `TextProcessor.swift` | **CREATE** — text extraction |
| `ContentProcessor.swift` | **CREATE** — protocol + SourceContext |
| `ContentAnalysisService.swift` | **CREATE** — extracted from ContentPipelineService |
| `ContentPipelineService.swift` | **SIMPLIFY** — `processEntry()` becomes thin wrapper that calls `TranscriptionPipeline.shared.run()`. `process()` removed. `activeJobs` removed. `pipelineStatus` removed. |
| `ContentExtractionService.swift` | **SIMPLIFY** — remove `extractTextFromAudio`, `transcribeSingleFile`. Keep OCR helpers, bookmark fetch, chunkText (used elsewhere). |
| `ProcessingQueueService.swift` | **SIMPLIFY** — remove polling fallback in `processNext()`. `finishJob()` simplified — item status is the truth. |
| `RecordingCoordinator.swift` | **SIMPLIFY** — remove contentPipeline fallback |
| `ChatView.swift` | **SIMPLIFY** — route through pipeline |
| `KnowledgeDetailView.swift` | **SIMPLIFY** — route through pipeline, refresh item |
| `WawaNoteCore/Models/KnowledgeItem.swift` | **MODIFIED** — lastErrorRaw, isTerminal, hard state machine |

## Verification

### Unit Tests
- `AudioProcessorTests`: each of 17 error cases produces correct status + lastErrorRaw
- `ImageProcessorTests`: each of 4 error cases
- `TextProcessorTests`: each of 3 error cases
- `TranscriptionPipelineTests`: terminal state guarantee, dedup, mode switching
- `ContentAnalysisServiceTests`: provider resolution, retry exhaustion

### Integration Tests (device)
1. Record → stop → verify `.transcribed` → `.pendingReview`
2. Record long (5min+) → stop → verify checkpoint resume
3. Manual re-transcribe → verify backup/restore on failure
4. No AI provider → verify `.failed` with error banner
5. Switch engine (Apple → Whisper) → verify new transcription
6. Force-kill during transcription → relaunch → verify recovery
7. Chat dictation → verify text appears in chat input
