# TASKS — Claude Code Execution Checklist

Claude Code should update this file as work is completed.

Use these statuses:

```text
[ ] not started
[/] in progress
[x] done
[!] blocked
```

## Phase 0 — Project setup

- [x] Create or inspect SwiftUI iOS app target.
- [x] Confirm bundle name and app display name.
- [x] Confirm minimum iOS target.
- [x] Add main app navigation shell.
- [x] Add tabs/sections: Home, Meetings, Chat, Settings.
- [x] Add basic placeholder screens.
- [x] Add project logging utility.
- [x] Confirm app builds.

## Phase 1 — Data and settings skeleton

- [x] Create domain models:
  - [x] Meeting
  - [x] TranscriptSegment
  - [x] MeetingAnalysis
  - [x] AIProviderConfig
  - [x] ChatConversation
  - [x] ChatMessage
- [x] Configure SwiftData or selected persistence.
- [x] Implement `FileArtifactStore`.
- [x] Implement `SecureKeyStore`.
- [x] Add provider settings screen.
- [x] Save provider metadata.
- [x] Save API key to Keychain.
- [x] Verify no secrets are stored in plain text.

## Phase 2 — Audio recording MVP

- [x] Add microphone permission text in Info.plist.
- [x] Implement `AudioSessionManager`.
- [x] Implement `AudioCaptureService`.
- [x] Implement audio file writing to Application Support.
- [x] Add Record UI:
  - [x] Start button
  - [x] Stop button
  - [x] timer
  - [x] status label
- [x] Save meeting metadata after recording.
- [x] Verify saved audio file exists.
- [x] Add simple playback or debug verification.

## Phase 3 — Apple transcription MVP

- [x] Add speech recognition permission text in Info.plist.
- [x] Define `TranscriptionEngine`.
- [x] Implement `AppleSpeechTranscriptionEngine`.
- [x] Request speech recognition authorization.
- [x] Transcribe saved audio file.
- [x] Convert result to transcript data.
- [x] Save transcript.
- [x] Display transcript in Meeting detail screen.
- [x] Add retry transcription action.

## Phase 4 — OpenAI-compatible provider MVP

- [x] Define `AIProvider`.
- [x] Define `AIRequest`, `AIResponse`, and `AIChunk`.
- [x] Implement `OpenAICompatibleProvider`.
- [x] Load provider config.
- [x] Retrieve API key from Keychain.
- [x] Send transcript to provider.
- [x] Parse provider response into internal type.
- [x] Hide provider-specific JSON from UI.
- [x] Add provider test action in Settings.

## Phase 5 — Meeting analysis MVP

- [x] Create `AnalysisService`.
- [x] Add structured meeting summary prompt.
- [x] Generate short summary.
- [x] Generate detailed summary.
- [x] Extract action items.
- [x] Extract decisions.
- [x] Extract open questions.
- [x] Extract risks/blockers.
- [x] Save `MeetingAnalysis`.
- [x] Display analysis sections in UI.
- [x] Preserve raw response when parse fails.

## Phase 6 — Export MVP

- [x] Implement Markdown exporter.
- [x] Implement JSON exporter.
- [x] Add ShareLink/share sheet.
- [x] Export meeting metadata.
- [x] Export transcript.
- [x] Export summary and action items.
- [x] Verify exported files open outside app.

## Phase 7 — Chat MVP

- [x] Add chat conversation model.
- [x] Add chat message model.
- [x] Add Chat UI.
- [x] Send message through selected `AIProvider`.
- [x] Save chat history.
- [x] Display response.
- [x] Add basic error handling.

## Phase 7.5 — Data Flow Stabilization

- [x] Create MeetingModel at recording start (not after stop).
- [x] Store audio in per-meeting folder as `audio.m4a`.
- [x] Remove legacy audio path fallback.
- [x] Fix transcript meetingId and segment meetingIds.
- [x] Fix analysis meetingId from transcript.
- [x] Use full UUIDs in analysis prompt for traceability.
- [x] Map source_segment_ids from provider response into domain objects.
- [x] Preserve raw provider response to file when parsing fails.
- [x] Clean up meeting artifacts on delete.
- [x] Clean up Keychain secrets on provider delete.

## Phase 8 — iPhone 14 Plus validation

- [ ] Test on iPhone 14 Plus.
- [ ] Record 5 minutes.
- [ ] Record 15 minutes.
- [ ] Record 60 minutes.
- [ ] Test screen lock.
- [ ] Test interruption.
- [ ] Test no network.
- [ ] Test provider failure.
- [ ] Test export.
- [ ] Update `docs/TEST_PLAN.md` with results.

## Backlog — not MVP 1

- [ ] WhisperKit engine.
- [ ] SpeechAnalyzer engine.
- [ ] Import audio files.
- [ ] Manual meeting markers.
- [ ] Local NLP service.
- [ ] Vision OCR attachments.
- [ ] Calendar integration.
- [ ] Reminders integration.
- [ ] Core Spotlight indexing.
- [ ] Face ID lock.
- [ ] Optional encrypted meeting archive.
