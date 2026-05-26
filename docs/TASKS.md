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

- [ ] Create or inspect SwiftUI iOS app target.
- [ ] Confirm bundle name and app display name.
- [ ] Confirm minimum iOS target.
- [ ] Add main app navigation shell.
- [ ] Add tabs/sections: Meetings, Record, Chat, Settings.
- [ ] Add basic placeholder screens.
- [ ] Add project logging utility.
- [ ] Confirm app builds.

## Phase 1 — Data and settings skeleton

- [ ] Create domain models:
  - [ ] Meeting
  - [ ] TranscriptSegment
  - [ ] MeetingAnalysis
  - [ ] AIProviderConfig
  - [ ] ChatConversation
  - [ ] ChatMessage
- [ ] Configure SwiftData or selected persistence.
- [ ] Implement `FileArtifactStore`.
- [ ] Implement `SecureKeyStore`.
- [ ] Add provider settings screen.
- [ ] Save provider metadata.
- [ ] Save API key to Keychain.
- [ ] Verify no secrets are stored in plain text.

## Phase 2 — Audio recording MVP

- [ ] Add microphone permission text in Info.plist.
- [ ] Implement `AudioSessionManager`.
- [ ] Implement `AudioCaptureService`.
- [ ] Implement audio file writing to Application Support.
- [ ] Add Record UI:
  - [ ] Start button
  - [ ] Stop button
  - [ ] timer
  - [ ] status label
- [ ] Save meeting metadata after recording.
- [ ] Verify saved audio file exists.
- [ ] Add simple playback or debug verification.

## Phase 3 — Apple transcription MVP

- [ ] Add speech recognition permission text in Info.plist.
- [ ] Define `TranscriptionEngine`.
- [ ] Implement `AppleSpeechTranscriptionEngine`.
- [ ] Request speech recognition authorization.
- [ ] Transcribe saved audio file.
- [ ] Convert result to transcript data.
- [ ] Save transcript.
- [ ] Display transcript in Meeting detail screen.
- [ ] Add retry transcription action.

## Phase 4 — OpenAI-compatible provider MVP

- [ ] Define `AIProvider`.
- [ ] Define `AIRequest`, `AIResponse`, and `AIChunk`.
- [ ] Implement `OpenAICompatibleProvider`.
- [ ] Load provider config.
- [ ] Retrieve API key from Keychain.
- [ ] Send transcript to provider.
- [ ] Parse provider response into internal type.
- [ ] Hide provider-specific JSON from UI.
- [ ] Add provider test action in Settings.

## Phase 5 — Meeting analysis MVP

- [ ] Create `AnalysisService`.
- [ ] Add structured meeting summary prompt.
- [ ] Generate short summary.
- [ ] Generate detailed summary.
- [ ] Extract action items.
- [ ] Extract decisions.
- [ ] Extract open questions.
- [ ] Extract risks/blockers.
- [ ] Save `MeetingAnalysis`.
- [ ] Display analysis sections in UI.
- [ ] Preserve raw response when parse fails.

## Phase 6 — Export MVP

- [ ] Implement Markdown exporter.
- [ ] Implement JSON exporter.
- [ ] Add ShareLink/share sheet.
- [ ] Export meeting metadata.
- [ ] Export transcript.
- [ ] Export summary and action items.
- [ ] Verify exported files open outside app.

## Phase 7 — Chat MVP

- [ ] Add chat conversation model.
- [ ] Add chat message model.
- [ ] Add Chat UI.
- [ ] Send message through selected `AIProvider`.
- [ ] Save chat history.
- [ ] Display response.
- [ ] Add basic error handling.

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
