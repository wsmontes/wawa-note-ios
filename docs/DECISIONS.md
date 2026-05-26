# Decisions — AI Meeting Companion iOS

Use this file as a lightweight Architecture Decision Record.

Claude Code should update this file when architecture or implementation direction changes.

## Format

```text
## ADR-000X — Title

Date:
Status: Proposed | Accepted | Superseded

Context:
Decision:
Consequences:
```

---

## ADR-0001 — Native iOS app with SwiftUI

Date: 2026-05-25  
Status: Accepted

Context:

The first target is an iPhone app built with Xcode and tested on iPhone 14 Plus.

Decision:

Use native iOS with Swift and SwiftUI.

Consequences:

- Good access to AVFoundation, Speech, Keychain, SwiftData, Vision, EventKit.
- Better fit for meeting recording than a web app.
- Requires Xcode/iOS-specific testing.

---

## ADR-0002 — Provider-agnostic AI architecture

Date: 2026-05-25  
Status: Accepted

Context:

The app must work with multiple AI providers and local-network providers.

Decision:

Create an `AIProvider` abstraction and keep provider-specific JSON inside provider implementations.

Consequences:

- Easier to support OpenAI, Gemini, Anthropic, LM Studio, Ollama-compatible endpoints.
- More initial architecture, less provider lock-in.
- UI and analysis code should never depend on provider-native JSON.

---

## ADR-0003 — Transcription engine abstraction

Date: 2026-05-25  
Status: Accepted

Context:

The app may use Apple Speech, SpeechAnalyzer, WhisperKit, or remote transcription.

Decision:

Create a `TranscriptionEngine` abstraction.

Consequences:

- MVP can start with Apple native transcription.
- WhisperKit can be added later without rewriting meeting workflow.
- Allows comparing engines on iPhone 14 Plus.

---

## ADR-0004 — Apple Foundation Models not MVP baseline

Date: 2026-05-25  
Status: Accepted

Context:

Target device is iPhone 14 Plus, which should not be treated as Apple Intelligence-capable.

Decision:

Do not make Apple Foundation Models a dependency of MVP 1.

Consequences:

- Heavy reasoning should use remote or local-network providers.
- Local intelligence should focus on Core ML, Natural Language, Vision, Sound Analysis, and WhisperKit experiments.
- Add Apple Foundation Models later as optional provider on supported devices.

---

## ADR-0005 — Hybrid storage model

Date: 2026-05-25  
Status: Accepted

Context:

Meeting data includes metadata, audio files, transcript JSON, analysis JSON, provider configs, and secrets.

Decision:

Use:

```text
SwiftData for metadata
FileManager for large artifacts
Keychain for secrets
```

Consequences:

- Audio files do not bloat the database.
- API keys remain secure.
- Export/import is easier.
- Need careful cleanup when deleting meetings.

---

## ADR-0006 — MVP starts with reliable recording, not advanced AI

Date: 2026-05-25  
Status: Accepted

Context:

The project has many possible advanced features.

Decision:

MVP must prove:

```text
record -> transcribe -> analyze -> save -> review -> export
```

Consequences:

- No WhisperKit in first implementation unless explicitly moved forward.
- No diarization, Calendar, Reminders, CloudKit, widgets, or Apple Foundation Models in MVP 1.
- Faster path to a working app on real iPhone.

---

## ADR-0007 — Use xcodegen for project generation

Date: 2026-05-25
Status: Accepted

Context:

The project needed an `.xcodeproj` to build. Manually constructing a
`project.pbxproj` is error-prone (~500+ lines of opaque plist). The
project had no existing Xcode project file.

Decision:

Use xcodegen (installed via Homebrew) with a `project.yml` spec at the
repo root. The generated `.xcodeproj` is committed to git. Developers
only need xcodegen when the project structure changes (new files,
new targets, new build settings).

Consequences:

- `project.yml` is the human-readable source of truth (~50 lines).
- `.xcodeproj` is committed for convenience (openable without xcodegen).
- Adding new files requires running `xcodegen generate` to update the
  pbxproj, or adding them manually in Xcode.
- CI can regenerate the project from `project.yml` for reproducibility.

---

## ADR-0008 — Home tab instead of Record as top-level tab

Date: 2026-05-25
Status: Accepted

Context:

The initial CLAUDE.md draft listed tabs as Meetings, Record, Chat,
Settings. The UX/UI manual (`docs/ux_ui_manual_ai_meeting_companion.md`)
specifies Home, Meetings, Chat, Settings with recording accessed from
Home via a "Start Meeting" button.

Decision:

Use Home as the first tab. Recording is a destination (full-screen cover
or navigation push from Home), not a tab. The Home tab can grow to
include setup status, recent meetings, and quick actions.

Consequences:

- Better matches the UX/UI manual and iOS navigation conventions.
- RecordView is a called screen, not a fixed tab.
- "Record" as a tab would waste a slot on something used only during
  active meetings; Home provides more utility.
