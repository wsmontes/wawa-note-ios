# Anarlog Ecosystem — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-215
**Source modules:** `Ecosystem/Anarlog/`

---

## Overview

The Anarlog ecosystem is a bidirectional import/export bridge between Wawa Note and external tools. It provides a standardized interchange format (Anarlog Document), watched folder sync, quality validation gates, speaker identity resolution, and compatibility with the Meetily ecosystem.

---

## Components (15 files)

### Core
| Component | File | Purpose |
|---|---|---|
| AnarlogDocument | `AnarlogDocument.swift` | Canonical document model: metadata, segments, speakers, annotations |
| AnarlogImporter | `AnarlogImporter.swift` | Parse Anarlog format → KnowledgeItem |
| AnarlogExporter | `AnarlogExporter.swift` | Export KnowledgeItem → Anarlog format |
| AnarlogSyncService | `AnarlogSyncService.swift` | Watched folder: detect new files → auto-import |

### Quality & Validation
| Component | File | Purpose |
|---|---|---|
| EvalSystem | `EvalSystem.swift` | AI output quality validation gates |
| SummaryCache | `SummaryCache.swift` | Cached AI summaries for fast lookup |

### Speaker & Audio
| Component | File | Purpose |
|---|---|---|
| SpeakerLabeler | `SpeakerLabeler.swift` | Cross-reference speaker names with Contacts |
| VoiceActivityDetector | `VoiceActivityDetector.swift` | VAD-based segment boundary detection |
| STTAdapters | `STTAdapters.swift` | Normalize speech-to-text output formats |

### Transcript
| Component | File | Purpose |
|---|---|---|
| TranscriptRenderer | `TranscriptRenderer.swift` | Format transcripts for display/export |
| TranscriptPatchService | `TranscriptPatchService.swift` | Apply corrections to transcript segments |

### Meetily Compatibility
| Component | File | Purpose |
|---|---|---|
| MeetilyImporter | `MeetilyImporter.swift` | Import Meetily format recordings |
| MeetilyExporter | `MeetilyExporter.swift` | Export to Meetily format |
| MeetilyTemplateService | `MeetilyTemplateService.swift` | Template mapping between formats |

### Configuration
| Component | File | Purpose |
|---|---|---|
| AnarlogConfigBridge | `AnarlogConfigBridge.swift` | Bridge Wawa Note config ↔ Anarlog format |
| AnarlogParticipantBridge | `AnarlogParticipantBridge.swift` | Map participant identities across systems |
| TemplateMapper | `TemplateMapper.swift` | Map analysis templates between formats |
| ModelResolver | `ModelResolver.swift` | Resolve AI model preferences |

---

## Anarlog Document Format

```json
{
  "version": "1.0",
  "metadata": {
    "title": "Q2 Planning Meeting",
    "recordedAt": "2026-06-15T10:00:00Z",
    "durationSeconds": 2700,
    "language": "en",
    "source": "wawa-note"
  },
  "segments": [
    {
      "startTime": 0.0,
      "endTime": 5.2,
      "speakerId": "spk_01",
      "text": "Welcome everyone to the Q2 planning session.",
      "confidence": 0.95
    }
  ],
  "speakers": [
    {
      "id": "spk_01",
      "displayName": "Wagner",
      "contactIdentifier": "ABC123"
    }
  ],
  "annotations": [
    {
      "source": "sentiment",
      "key": "overall",
      "value": "positive",
      "confidence": 0.85
    }
  ]
}
```

---

## Watched Folder Sync (AnarlogSyncService)

1. User configures a watched folder (via Settings → AnarlogSyncSettingsView)
2. Folder bookmark saved with security-scoped access
3. `AnarlogSyncService` monitors folder using FSEvents
4. New `.anarlog.json` files detected → queued for import
5. Import: `AnarlogImporter` parses → `KnowledgeItemService.createItem()`
6. Post-import: `EvalSystem` validates quality → `SpeakerLabeler` resolves identities
7. Item appears in Inbox → Needs Review

---

## EvalSystem

Quality validation gate that runs on imported Anarlog documents before they enter the knowledge store:

- **Completeness check:** required fields present (title, segments, speakers)
- **Confidence threshold:** segments with confidence < 0.5 flagged
- **Speaker coverage:** at least 50% of segments must have speaker assignment
- **Duration sanity:** recorded duration must match segment total (±10%)
- **Language detection:** language field must be valid BCP-47

Failed validation → item flagged, user notified, held for review.
Passed validation → normal import flow.

---

## SpeakerLabeler

Resolves speaker identities by cross-referencing:
1. Display names in Anarlog document
2. Contacts (CNContactStore) — match by name/email
3. Previous Wawa Note meetings — match by voice pattern (future)
4. Calendar event attendees (EKEventStore) — match by name

Output: enriched speaker entries with contact identifiers and confidence scores.

---

## VoiceActivityDetector

Integration point for VAD-based segment boundary detection:
- Uses WebRTC VAD or similar
- Detects speech vs. silence transitions
- Produces segment boundaries for transcription alignment
- Improves transcript accuracy by providing precise utterance timing

---

## User Journey

See `USER_JOURNEYS.md` → Journey 8: Anarlog Sync → Import → Triage.
