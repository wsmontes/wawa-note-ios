# Implementation Plan — AI Meeting Companion iOS

## 1. Strategy

Build the app in thin vertical slices.

Do not start by implementing every module. Start with the smallest reliable loop:

```text
record -> save audio -> transcribe -> analyze -> save -> display -> export
```

The project should first prove that meeting recording and analysis work on a real iPhone 14 Plus.

## 2. Phase 0 — Project setup

Goal:

Create a clean native iOS SwiftUI project foundation.

Tasks:

- Create SwiftUI iOS app target.
- Set minimum iOS target after checking Xcode environment.
- Add basic app navigation.
- Add tabs or main sections:
  - Meetings
  - Record
  - Chat
  - Settings
- Add docs folder to repo.
- Add `CLAUDE.md`.
- Add placeholder domain models.
- Add basic logging utility.

Acceptance criteria:

- Project builds in Xcode.
- App launches on simulator.
- Main navigation is visible.
- No provider or audio implementation yet.

## 3. Phase 1 — Local data and settings skeleton

Goal:

Set up the data model and provider configuration foundation.

Tasks:

- Implement basic `Meeting` model.
- Implement basic `TranscriptSegment` model.
- Implement basic `MeetingAnalysis` model.
- Implement basic `AIProviderConfig` model.
- Add SwiftData container or selected persistence layer.
- Add `FileArtifactStore`.
- Add `SecureKeyStore` using Keychain.
- Add Settings screen for provider configuration metadata.
- Store API keys in Keychain only.

Acceptance criteria:

- User can create/edit a provider config.
- API key is stored in Keychain.
- Provider metadata is stored outside Keychain.
- No secrets are visible in local JSON/SwiftData.

## 4. Phase 2 — Audio recording MVP

Goal:

Record meeting audio and save it locally.

Tasks:

- Implement `AudioSessionManager`.
- Implement `AudioCaptureService`.
- Implement local audio file writing.
- Add Record screen:
  - Start
  - Stop
  - timer
  - recording status
  - audio level indicator, if simple
- Save meeting metadata after recording.
- Store audio under app Application Support folder.

Acceptance criteria:

- User can record audio.
- Audio file is saved.
- Meeting metadata points to the audio file.
- Audio can be played back or verified.
- App does not lose file on stop.

## 5. Phase 3 — Apple transcription MVP

Goal:

Transcribe saved audio through a native Apple transcription engine.

Tasks:

- Define `TranscriptionEngine`.
- Implement `AppleSpeechTranscriptionEngine`.
- Ask for speech recognition permission.
- Convert transcription results into `TranscriptSegment`.
- Save transcript segments.
- Show transcript in Meeting detail screen.

Acceptance criteria:

- Recorded audio can be transcribed.
- Transcript is displayed.
- Transcript is stored.
- Transcript is not stored only as one unstructured blob if segment data is available.
- Transcription errors are visible and recoverable.

## 6. Phase 4 — AI provider MVP

Goal:

Use an OpenAI-compatible endpoint to analyze transcripts.

Tasks:

- Define `AIProvider`.
- Define `AIRequest`, `AIResponse`, `AIChunk`.
- Implement `OpenAICompatibleProvider`.
- Support configurable base URL, model, and API key.
- Implement non-streaming completion first.
- Add provider health/test call if simple.
- Add `AnalysisService`.

Acceptance criteria:

- User can configure an OpenAI-compatible endpoint.
- App can send transcript to provider.
- App receives response.
- Provider-specific JSON is isolated in provider implementation.
- No API key appears in logs.

## 7. Phase 5 — Meeting summary MVP

Goal:

Generate useful meeting summaries.

Tasks:

- Add meeting analysis prompt.
- Ask provider for structured JSON when possible.
- Parse response into `MeetingAnalysis`.
- Store analysis.
- Show summary screen.
- Include:
  - short summary
  - detailed summary
  - action items
  - decisions
  - open questions
  - risks

Acceptance criteria:

- After transcription, user can generate summary.
- Summary is saved.
- UI displays structured sections.
- If JSON parsing fails, raw response is preserved for debugging.

## 8. Phase 6 — Export MVP

Goal:

Allow exporting meeting result.

Tasks:

- Implement Markdown export.
- Implement JSON export.
- Use ShareLink or share sheet.
- Export:
  - meeting metadata
  - summary
  - action items
  - transcript

Acceptance criteria:

- User can export a Markdown file.
- User can export JSON.
- Exported content is readable outside the app.

## 9. Phase 7 — Chat MVP

Goal:

Provide a basic provider-agnostic chat screen.

Tasks:

- Add `ChatConversation` and `ChatMessage` models.
- Use the existing `AIProvider` abstraction.
- Add Chat screen.
- Support one selected provider/model.
- Support basic message history.

Acceptance criteria:

- User can send text message.
- Provider responds.
- Conversation is saved.
- Chat does not bypass provider abstraction.

## 10. Phase 8 — MVP hardening

Goal:

Make the core loop reliable on iPhone 14 Plus.

Tasks:

- Test 5-minute recording.
- Test 15-minute recording.
- Test 60-minute recording.
- Test screen-lock behavior.
- Test interruption handling.
- Test provider failure.
- Test no-network behavior.
- Improve user-facing errors.
- Update `docs/TEST_PLAN.md`.

Acceptance criteria:

- Known limitations documented.
- App does not silently lose audio.
- Failed transcription/analysis can be retried.
- Build is stable.

## 11. Post-MVP candidates

Only after MVP loop works:

- WhisperKit.
- SpeechAnalyzer.
- Manual meeting markers.
- Import existing audio.
- Local NLP language/entity extraction.
- Calendar association.
- Reminders export.
- OCR attachments.
- Local search.
- Core Spotlight.
- Face ID lock.
- CryptoKit encrypted archive.
