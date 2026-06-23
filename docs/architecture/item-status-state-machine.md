# ItemStatus State Machine

> KAN-87 — Documented and enforced via `transitionStatus(to:reason:)`

## States (12)

| # | State | Description |
|---|-------|-------------|
| 1 | `draft` | Initial state for new items |
| 2 | `recording` | Audio capture in progress |
| 3 | `preparingAudio` | Audio segments being concatenated to audio.m4a |
| 4 | `queuedForTranscription` | In processing queue, waiting for transcription slot |
| 5 | `recorded` | Legacy: recording complete (pre-queue era) |
| 6 | `transcribing` | Speech-to-text in progress |
| 7 | `transcribed` | Transcription complete |
| 8 | `pendingReview` | User must review extraction before analysis proceeds |
| 9 | `analyzing` | AI analysis in progress |
| 10 | `analyzed` | Analysis complete, results available |
| 11 | `failed` | Terminal: processing failed (retryable → queuedForTranscription/recorded) |
| 12 | `archived` | Terminal: manually archived |

## State Diagram

```
draft
  │
  ▼
recording ──────────────► failed
  │                         ▲
  ▼                         │
preparingAudio ─────────────┤
  │                         │
  ▼                         │
queuedForTranscription ─────┤
  │  ▲                      │
  ▼  │ (retry)              │
transcribing ───────────────┤
  │                         │
  ▼                         │
transcribed ────────────────┤
  │                         │
  ├──────────┐              │
  ▼          ▼              │
pendingReview  analyzing ───┤
  │          │              │
  ▼          ▼              │
analyzing   analyzed ───────┘
  │
  ▼
analyzed

Any state ──► archived (manual, terminal)
failed ────► queuedForTranscription | recorded (retry)
```

## Valid Transitions

```swift
draft          → [recording]
recording      → [preparingAudio, recorded, failed]
preparingAudio → [queuedForTranscription, failed]
queuedForTranscription → [transcribing, failed]
recorded       → [transcribing, queuedForTranscription, failed]
transcribing   → [transcribed, failed]
transcribed    → [pendingReview, analyzing, failed]
pendingReview  → [analyzing, failed]
analyzing      → [analyzed, failed]
analyzed       → [failed]
failed         → [queuedForTranscription, recorded]
archived       → [] (terminal)
```

## Enforcement

**File:** `wawa-note/Domain/Models/KnowledgeItem.swift:191-199`

```swift
func transitionStatus(to next: ItemStatus, reason: String) {
    guard current.canTransition(to: next) else {
        AppLog.warn("status", "⚠️ Illegal state transition: \(current) → \(next) — \(reason)")
        // Still allows for backwards compatibility, but logs warning
    }
    self.status = next
}
```

**Rule:** All status changes must use `item.transitionStatus(to:reason:)` — never `item.status = .something` directly. The method validates and logs illegal transitions.
