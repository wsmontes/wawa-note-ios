# CLAUDE.md — AI Meeting Companion iOS

## Project identity

This is a native iOS app for iPhone: **AI Meeting Companion / Universal AI Client**.

Core idea:

> Apple-native shell + provider-agnostic AI core + local-first data model.

The app must record meetings, transcribe audio, summarize content, extract structured meeting intelligence, and support multiple AI providers through clean abstractions.

## Source-of-truth documents

Before making architecture decisions, read these files:

1. `docs/PROJECT_SPEC.md` — product vision, functional requirements, MVP scope.
2. `docs/APPLE_TECH_INVENTORY.md` — Apple/iPhone 14 Plus technical constraints.
3. `docs/ARCHITECTURE.md` — intended app architecture and module boundaries.
4. `docs/IMPLEMENTATION_PLAN.md` — phased implementation plan.
5. `docs/TASKS.md` — current executable task list.
6. `docs/CODING_STANDARDS.md` — coding rules and conventions.
7. `docs/DATA_MODEL.md` — domain models and storage strategy.
8. `docs/API_PROVIDER_CONTRACTS.md` — provider and transcription abstractions.
9. `docs/SECURITY_PRIVACY.md` — permissions, secrets, privacy modes.
10. `docs/TEST_PLAN.md` — build, simulator, and iPhone 14 Plus validation.

## Current MVP target

Build MVP 1 first:

1. SwiftUI app shell.
2. Local audio recording.
3. Save `.m4a` audio locally.
4. Native Apple speech transcription behind `TranscriptionEngine`.
5. OpenAI-compatible provider behind `AIProvider`.
6. Keychain storage for API keys.
7. SwiftData metadata + FileManager artifacts.
8. Meeting summary generation.
9. Markdown/JSON export.

MVP 1 success loop:

```text
record -> transcribe -> analyze -> save -> review -> export
```

## Hard constraints

- Target first real device: **iPhone 14 Plus**.
- Do not make Apple Intelligence or Foundation Models a required feature.
- Do not implement a backend unless explicitly requested.
- Do not hard-code API keys, provider URLs, or secrets.
- Do not store secrets in SwiftData, JSON, UserDefaults, or source files.
- Use Keychain for API keys.
- Use FileManager for large artifacts such as audio and transcript JSON.
- Use SwiftData only for metadata and indexable records.
- Do not put audio/transcription/networking logic directly inside SwiftUI views.
- Do not let provider-specific JSON leak across the app.
- Keep audio, transcript, analysis, and chat as separate layers.
- Keep original raw audio and original transcript recoverable unless the user deletes them.

## Architectural rules

Use protocol-first boundaries:

```swift
protocol AIProvider { ... }
protocol TranscriptionEngine { ... }
protocol AudioCaptureService { ... }
protocol SecureKeyStore { ... }
protocol MeetingRepository { ... }
```

Provider-specific implementations belong under provider modules, not in views.

Recommended layers:

```text
App/UI
Domain
Audio
Transcription
Providers
Storage
LocalIntelligence
EcosystemIntegrations
```

## Implementation behavior

For any non-trivial change:

1. Inspect existing files first.
2. Update `docs/TASKS.md` status before and after implementation.
3. Make one coherent change at a time.
4. Prefer small files with clear responsibilities.
5. Run build/tests when available.
6. Update docs when architectural decisions change.
7. Record important decisions in `docs/DECISIONS.md`.

## Swift style

- Use Swift Concurrency (`async/await`) for async flows.
- Use `@MainActor` for UI-facing view models.
- Use `ObservableObject` or modern Observation depending on project target.
- Keep SwiftUI views thin.
- Keep services testable without UI.
- Prefer dependency injection through initializers.
- Avoid global mutable singletons unless wrapping stable system APIs.
- Prefer strongly typed models over dictionaries.
- Handle errors explicitly with typed error enums where practical.

## First coding priority

If the app is empty, start with:

1. Xcode SwiftUI iOS app structure.
2. Basic tab/navigation shell:
   - Meetings
   - Record
   - Chat
   - Settings
3. Domain models.
4. Local artifact folder service.
5. Keychain service skeleton.
6. Provider config screen.
7. Audio recording service.

Do not start with WhisperKit, diarization, Calendar, Reminders, CloudKit, widgets, or Apple Foundation Models before the MVP loop works.

## When uncertain

Choose the simpler option that preserves the architecture.

Document uncertainty in `docs/DECISIONS.md` instead of overbuilding.
