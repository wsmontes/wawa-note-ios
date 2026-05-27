# Wawa Note iOS — Phase Audit: Missing Items and New Problems

Date: 2026-05-26  
Input reviewed: `wawa-note-ios.zip`  
Scope: review of the current repository contents after the reported 8-phase implementation cycle.

---

## 1. Executive Summary

The project is in a much better state than the first foundation commit. There is now a real SwiftUI app structure, domain models, storage skeleton, audio capture classes, Apple Speech transcription integration, OpenAI-compatible provider integration, meeting analysis, export, and chat screens.

However, the current state should **not** be considered a fully validated MVP yet.

The repository currently looks like a strong **prototype implementation of Phases 0–7**, but Phase 8 is still open, and several important issues were introduced while connecting the vertical slice.

The biggest finding is this:

> The app has many components needed for the MVP loop, but the data flow is not yet coherent enough to be trusted in real use.

The intended loop is:

```text
record -> save audio -> transcribe -> analyze -> save -> display -> export
```

The code attempts this loop, but there are gaps in:

- audio file location consistency,
- meeting ID propagation,
- transcript-to-analysis traceability,
- raw provider response preservation,
- provider type correctness,
- real-device validation,
- error handling,
- deletion/cleanup behavior,
- build/test evidence,
- repository cleanliness.

My recommendation is to treat the current state as:

```text
Prototype complete through Phase 7, but not MVP-complete until a stabilization phase fixes the critical data-flow issues and Phase 8 validates on iPhone 14 Plus.
```

---

## 2. Repository State Observations

## 2.1 Important Git State Issue

The uploaded zip contains a `.git` folder. The repository `HEAD` is at:

```text
6d4d277 Sync Phase 0 status, fix tab naming, and add reusable UI components
```

But the actual files in the zip include many changes beyond that commit.

`git status` shows the implementation for later phases as **uncommitted changes**.

This is important because the current zip is not a clean committed state. The app may represent the result of phases 1–7, but Git does not yet represent that as a committed history.

### What is missing

- A clean commit for the current implementation state.
- A phase-by-phase commit history, or at least a final commit named clearly, e.g.:

```text
Implement MVP loop through Phase 7
```

### New problem

The project documentation says Phase 7 is complete, but the Git commit history does not show those phases as committed. That makes it harder to review, bisect, rollback, or hand off to Claude Code safely.

---

## 2.2 Build Verification Could Not Be Independently Confirmed Here

The `docs/SESSION_LOG.md` says there was a successful build with 0 errors and 0 Swift warnings during Phase 4.

However, in this review environment I cannot run `xcodebuild` because Xcode is not available here.

### What is missing

- A current build result after all Phase 1–7 changes.
- A recorded build command and destination, ideally:

```bash
xcodebuild -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build
```

### New problem

There are possible compile risks in the current source, especially around `@Published` usage in non-UI service files without explicit `Combine` imports.

Files of concern:

- `AudioCaptureService.swift`
- `AudioPlaybackService.swift`

Both use `@Published`, but import only `AVFoundation` and `OSLog`. If Swift does not resolve `Published` through another imported module, this will fail compilation. The safe fix is to import `Combine`, or redesign service state propagation.

---

## 3. Phase-by-Phase Audit

---

# Phase 0 — Project Setup

## Expected goal

Create a clean native iOS SwiftUI project foundation with:

- SwiftUI app target,
- basic navigation,
- docs,
- `CLAUDE.md`,
- placeholder models,
- logging utility,
- successful build.

## Current state

Mostly done.

Implemented:

- Native SwiftUI project structure.
- `WawaNoteApp` with SwiftData container.
- `ContentView` with `TabView`.
- Main tabs:
  - Home,
  - Meetings,
  - Chat,
  - Settings.
- Documentation folder.
- `CLAUDE.md`.
- `Logging.swift`.
- `project.yml`.
- `.xcodeproj`.

## What is still missing

### 0.1 Clean committed state

The current working tree is dirty. Phase 1–7 work is present as uncommitted changes.

This should be cleaned up before further development.

### 0.2 Current build confirmation

The docs claim builds succeeded earlier, but the current all-phase state still needs a fresh build confirmation.

### 0.3 Build reproducibility policy

The repo contains both:

```text
project.yml
wawa-note.xcodeproj
```

This is fine, but the rule must be explicit:

> `project.yml` is the source of truth; regenerate `.xcodeproj` when files change.

This rule exists in ADR-0007, but the workflow still needs to be enforced.

## New problems found

### 0.A Git and delivery mismatch

The repository commit history does not match the phase-completion claim.

### 0.B Documentation overstates current confidence

`PROJECT_STATUS.md` says the MVP loop is fully functional. Based on static review, the components exist, but the loop has critical data consistency issues and has not been validated on the real target device.

---

# Phase 1 — Local Data and Settings Skeleton

## Expected goal

Set up data model and provider configuration foundation:

- `Meeting`,
- `TranscriptSegment`,
- `MeetingAnalysis`,
- `AIProviderConfig`,
- persistence,
- file artifact store,
- Keychain,
- provider settings UI.

## Current state

Partially done, with good structure.

Implemented:

- Domain structs:
  - `Meeting`,
  - `TranscriptSegment`,
  - `Transcript`,
  - `Speaker`,
  - `MeetingAnalysis`,
  - `AIProviderConfig`,
  - chat models.
- SwiftData models:
  - `MeetingModel`,
  - `AIProviderConfigModel`,
  - `ChatConversationModel`,
  - `ChatMessageModel`.
- `FileArtifactStore`.
- `SecureKeyStore`.
- Provider list/editor screens.

## What is still missing

### 1.1 Transcript and analysis are not first-class persisted models

Transcript and analysis are stored as JSON files, not SwiftData records.

That is not automatically wrong, but the docs need to say this is the chosen design. Right now the implementation creates a mixed reality:

- meeting metadata in SwiftData,
- transcript JSON in file store,
- analysis JSON in file store,
- no explicit SwiftData relationship between meeting and artifacts.

### 1.2 No cleanup coupling between SwiftData and file artifacts

Deleting a meeting from `MeetingsListView` deletes only the SwiftData record.

It does not delete:

- audio file,
- transcript JSON,
- analysis JSON,
- exports folder.

This will leave orphaned files.

### 1.3 Provider deletion does not delete Keychain secret

Deleting a provider from `ProviderListView` deletes the SwiftData provider metadata, but does not delete the associated API key from Keychain.

### 1.4 Provider selection is not modeled

The app always fetches the first provider from SwiftData.

There is no concept of:

- active provider,
- default provider,
- provider per meeting,
- provider per chat,
- provider priority,
- provider disabled/enabled.

### 1.5 Privacy mode is not modeled

The specs require privacy-aware operation, but there is no persistence model for:

- local-only,
- local transcription + remote analysis,
- remote transcription,
- manual per meeting.

Settings shows `Local first`, but it is static UI text.

## New problems found

### 1.A Duplicate domain models and SwiftData models can drift

There are separate structs and SwiftData classes for similar concepts.

Example:

- `Meeting` struct,
- `MeetingModel` SwiftData model.

This can be fine, but there are no mapping functions or repository boundaries yet. Without a clear mapping strategy, fields can drift.

### 1.B Keychain errors are swallowed

Provider save/test code uses `try?` in several places. This hides failures saving or deleting API keys.

For a privacy/security-sensitive app, this should not be silent.

### 1.C API key can be loaded into UI state

`ProviderEditorViewModel` loads the API key into a plain `@Published var apiKey`. This is probably acceptable for editing, but it increases accidental exposure risk through debugging/logging/screenshots.

A safer UX is usually:

```text
API key saved. Leave blank to keep existing key.
```

or:

```text
Replace API key
```

instead of showing/reloading the existing key into editable state.

---

# Phase 2 — Audio Recording MVP

## Expected goal

Record meeting audio and save locally:

- `AudioSessionManager`,
- `AudioCaptureService`,
- local audio file writing,
- Record screen,
- start/stop/timer/status,
- save meeting metadata,
- verify audio file exists,
- playback/debug verification.

## Current state

Partially implemented.

Implemented:

- `AudioSessionManager`.
- `AudioCaptureService`.
- `AudioFileWriter`.
- `AudioPlaybackService`.
- `RecordView`.
- `RecordingViewModel`.
- Microphone permission text.
- Start/stop/pause/resume UI.
- Timer.
- Basic audio level meter.
- Meeting metadata is created after stopping.
- Playback after stop is available.

## What is still missing

### 2.1 Audio storage path is inconsistent with artifact architecture

`AudioFileWriter` writes audio here:

```text
Application Support/Meetings/{randomUUID}.m4a
```

But `FileArtifactStore` expects this structure:

```text
Application Support/Meetings/{meetingId}/audio.m4a
```

`MeetingDetailView` currently contains a fallback called `legacyURL` to find the random file.

This is the largest Phase 2 architecture issue.

The correct storage should be:

```text
Application Support/Meetings/{meetingId}/audio.m4a
Application Support/Meetings/{meetingId}/transcript.json
Application Support/Meetings/{meetingId}/analysis.json
```

### 2.2 Meeting is created after recording, not before

Because the meeting ID is created only after the recording stops, the audio writer cannot save directly into the meeting folder.

For a reliable meeting app, create the `MeetingModel` at recording start, then write audio into its folder.

Expected flow:

```text
Start Recording
 -> create MeetingModel(status: recording)
 -> create meeting folder
 -> write audio.m4a in meeting folder
 -> update status on stop
```

### 2.3 No incremental meeting state saving

The spec requires reliability for long meetings. The app currently does not appear to save meeting state at the start of recording. If the app crashes during recording, the audio file may exist but not be linked to a meeting.

### 2.4 Pause/resume timer is inaccurate

`recordingStartDate` is not adjusted for pause time. After pause/resume, elapsed time appears to include paused duration.

### 2.5 No interruption handling

There is no handling for:

- incoming calls,
- Siri/audio interruptions,
- route changes,
- headphones/Bluetooth route changes,
- app going inactive/background,
- audio session interruption notifications.

### 2.6 No screen-lock/background validation

No evidence that recording continues safely under screen lock or app lifecycle changes.

### 2.7 No “open saved meeting” path after recording

After recording stops, the UI says the meeting is saved, but the main action is just `Done`. It does not take the user to the meeting detail/transcription flow.

This interrupts the core MVP loop.

## New problems found

### 2.A Audio service state may not be thread-safe

`AudioCaptureService` mutates `@Published` properties from the AVAudioEngine tap callback. That callback is not guaranteed to be on the main thread.

This can cause concurrency issues or UI update warnings.

### 2.B `@Published` service classes lack explicit `Combine` import

`AudioCaptureService` and `AudioPlaybackService` use `@Published` but do not import `Combine`.

### 2.C Audio format assumptions need device testing

`AudioFileWriter` writes AAC `.m4a` using settings combined with the input format's `commonFormat` and interleaving. This may work, but it needs real-device validation. If it fails, this will be a major blocker.

---

# Phase 3 — Apple Transcription MVP

## Expected goal

Transcribe saved audio through native Apple transcription:

- `TranscriptionEngine`,
- `AppleSpeechTranscriptionEngine`,
- speech permission,
- transcript segments,
- save transcript,
- display transcript,
- retry.

## Current state

Partially implemented.

Implemented:

- `TranscriptionEngine` protocol.
- `AppleSpeechTranscriptionEngine`.
- Speech permission text.
- `SFSpeechURLRecognitionRequest`.
- Conversion to `TranscriptSegment`.
- Transcript save to `transcript.json`.
- Transcript display in meeting detail.
- Retry transcription button.

## What is still missing

### 3.1 Transcript segments use the wrong meeting ID

Inside `AppleSpeechTranscriptionEngine`, each segment is created with:

```swift
meetingId: UUID()
```

That means every segment gets a random meeting ID unrelated to the actual meeting.

Also, the returned `Transcript` does not set `meetingId`.

Consequences:

- analysis may be linked to a random meeting ID,
- evidence traceability breaks,
- transcript segments cannot reliably point back to their meeting,
- exported data can become internally inconsistent.

### 3.2 Analysis receives transcript without meeting ID

`AnalysisService` creates the analysis with:

```swift
meetingId: transcript.meetingId ?? UUID()
```

Since `transcript.meetingId` is likely nil, analysis can be saved with a random meeting ID inside the JSON, even though it is stored under the real meeting folder.

### 3.3 Transcript is token/word-level, not conversational segments

Apple Speech `bestTranscription.segments` usually represents word/subword-level segments. The app displays each segment directly, which may create a poor transcript UI.

For meeting use, we need higher-level segments, for example:

- sentence-level,
- time-window chunks,
- speaker turns later,
- paragraph-like blocks.

### 3.4 No locale/language selection

The engine is hardcoded to:

```swift
Locale(identifier: "en-US")
```

This does not match the expected multilingual use case, especially English/Portuguese meetings.

### 3.5 No timeout/cancellation protection

The `withCheckedThrowingContinuation` can hang if the recognizer does not call final result or error.

Also, recognition callbacks may risk multiple continuation resumes if not guarded carefully.

### 3.6 No long-audio chunking

Long recordings can exceed practical limits for Apple Speech requests. There is no chunking or fallback strategy.

## New problems found

### 3.A Evidence architecture is currently broken

The spec requires AI claims to be traceable back to transcript segments. The current transcription and analysis flow does not preserve this reliably.

### 3.B Transcript JSON location depends on Phase 2 workaround

Because audio is not stored in the final per-meeting folder, transcription has to search both:

```text
Application Support/Meetings/{meetingId}/{relativePath}
Application Support/Meetings/{relativePath}
```

This should not remain.

---

# Phase 4 — OpenAI-Compatible Provider MVP

## Expected goal

Use an OpenAI-compatible endpoint to analyze transcripts:

- `AIProvider`,
- `AIRequest`, `AIResponse`, `AIChunk`,
- `OpenAICompatibleProvider`,
- configurable base URL/model/API key,
- non-streaming completion,
- test connection,
- isolated provider JSON,
- no API keys in logs.

## Current state

Mostly implemented for the happy path.

Implemented:

- `AIProvider` protocol.
- `AIRequest`, `AIResponse`, `AIMessage`, `AIContentBlock`, `AIUsage`.
- `OpenAICompatibleProvider`.
- `ProviderRouter`.
- Provider editor UI.
- Test connection action.
- API key storage/retrieval through Keychain.
- Provider-specific request/response DTOs isolated inside provider implementation.

## What is still missing

### 4.1 No `AIChunk` despite phase requirement

The implementation does not define `AIChunk`, even though Phase 4 expected it.

Streaming is not used yet, but the abstraction is incomplete relative to the plan.

### 4.2 Provider type is cosmetic

The UI supports provider types:

- OpenAI-compatible,
- OpenAI,
- Anthropic,
- Gemini,
- Local Network,
- Apple Local.

But `ProviderRouter` always returns `OpenAICompatibleProvider`.

This is acceptable only if clearly documented as temporary. Right now, the UI implies broader support than the code provides.

### 4.3 Local network provider still requires API key

The original plan allowed optional API keys for local providers. Current router requires `apiKeyKeychainIdentifier` for all provider configs.

This may block LM Studio/Ollama-like usage if no key is needed.

### 4.4 No local network permission text

If the app connects to a local model on the LAN, iOS may require local network usage description.

`NSLocalNetworkUsageDescription` is not present yet.

### 4.5 No provider model list

The app does not load available models from the provider.

The user must type a model manually.

### 4.6 No provider selection in chat or analysis

The app simply picks the first provider from SwiftData.

### 4.7 No robust provider error messages

Some errors are reduced to:

```text
Could not connect
Could not connect to provider
Failed to get response
```

Need distinguish:

- invalid URL,
- no local network permission,
- DNS/network down,
- timeout,
- unauthorized,
- model not found,
- provider returned non-JSON,
- server incompatible.

## New problems found

### 4.A Provider logs may leak content

`OpenAICompatibleProvider` logs the first 100 characters of the provider response.

For a meeting app, this can leak sensitive meeting content into logs.

Recommendation:

- never log provider response content by default,
- log only metadata such as status, model, token count,
- add explicit debug mode if needed.

### 4.B Structured-output capability is mapped incorrectly

In `ProviderRouter`, this line appears conceptually wrong:

```swift
supportsStructuredOutput: config.supportsTools
```

Structured output and tools/function calling are different capabilities.

### 4.C Base URL normalization is fragile

The provider appends:

```swift
chat/completions
```

to whatever base URL the user enters.

If the user enters:

```text
http://server:1234
```

instead of:

```text
http://server:1234/v1
```

the request will be wrong. The UI should make this explicit or normalize/test endpoints.

---

# Phase 5 — Meeting Analysis MVP

## Expected goal

Generate useful structured meeting summaries:

- summary prompt,
- structured JSON,
- parse into `MeetingAnalysis`,
- save analysis,
- display sections,
- preserve raw response when parsing fails.

## Current state

Partially implemented.

Implemented:

- `AnalysisService`.
- Structured prompt.
- JSON response request with `responseFormat: .json`.
- `AnalysisResponse` DTO.
- Mapping to `MeetingAnalysis`.
- Analysis save to `analysis.json`.
- Summary UI sections.
- Fallback analysis object if parsing fails.

## What is still missing

### 5.1 Source segment IDs are requested but discarded

The prompt asks for `source_segment_ids`, and the DTO parses them, but `buildAnalysis` maps every result with:

```swift
sourceSegmentIds: []
```

This breaks the traceability requirement.

### 5.2 Segment IDs in prompt are truncated

The prompt uses:

```swift
segment.id.uuidString.prefix(8)
```

But `sourceSegmentIds` expects `[UUID]` in domain models.

Even if parsing were implemented, the returned short IDs cannot be directly parsed as full UUIDs.

Need either:

- use full UUIDs in prompt,
- use stable short IDs as strings,
- maintain a short ID -> UUID map.

### 5.3 Important dates are parsed from DTO but ignored

`importantDates` is decoded but not mapped into `MeetingAnalysis`.

The code has:

```swift
importantDates: []  // TODO
```

### 5.4 Entities are requested but ignored

`mentionedPeople` and `mentionedSystems` are decoded but not mapped into `entities`.

### 5.5 Topic timeline is not generated

The spec expects topic blocks eventually, and the UI manual expects meeting review to expose topics later. The current analysis prompt does not request topic timeline, and the UI does not show it.

This may be acceptable for early MVP, but should be marked as incomplete.

### 5.6 Follow-up email draft is requested but not stored or displayed

The prompt asks for `follow_up_email_draft`, but the domain model has no field for it, and the UI does not display it.

### 5.7 Raw response is not actually preserved as a file

When parsing fails, `buildFallbackAnalysis` stores raw content in `detailedSummary`, but:

```swift
rawProviderResponsePath: nil
```

The phase acceptance criteria said raw response should be preserved for debugging. The current implementation only partly satisfies this and mixes raw provider output into user-facing analysis.

### 5.8 Analysis status update condition is wrong

The code sets meeting status to analyzed only if:

```swift
!result.shortSummary.isEmpty && result.shortSummary != result.detailedSummary
```

This is arbitrary. A valid analysis can have short summary equal to detailed summary, especially in a short meeting.

## New problems found

### 5.A The current AI traceability promise is not met

The product spec and UX manual emphasize traceability from AI output back to transcript segments. This is currently not implemented.

### 5.B The UI can show fallback raw provider text as a “detailed summary”

If parsing fails, the app may display raw provider content inside the summary UI. This violates the UX rule that raw provider output should not be the normal user-facing experience.

### 5.C Analysis JSON may contain wrong meeting ID

Because transcript meeting ID is not set correctly, `MeetingAnalysis.meetingId` may be random inside the saved JSON file.

---

# Phase 6 — Export MVP

## Expected goal

Export meeting result:

- Markdown export,
- JSON export,
- ShareLink/share sheet,
- metadata,
- transcript,
- summary/action items,
- readable outside app.

## Current state

Mostly implemented, but not fully robust.

Implemented:

- `MarkdownExporter`.
- `JSONExporter`.
- Share menu in `MeetingDetailView`.
- Markdown text export.
- JSON temp file export.
- Includes meeting metadata, transcript, and analysis where available.

## What is still missing

### 6.1 Markdown export is shared as text, not as a `.md` file

This line shares a string:

```swift
ShareLink(item: viewModel.exportMarkdown(for: meeting))
```

That may be acceptable for basic sharing, but it does not guarantee a Markdown file is created/opened outside the app.

Acceptance criteria said exported content should be readable outside the app. It did not strictly require a `.md` file, but the task says “Markdown exporter”; practically we should create a real `.md` file.

### 6.2 JSON temp filename is not sanitized

JSON file path uses:

```swift
"\(meeting.title).json"
```

Meeting titles may contain characters that are awkward or invalid in filenames.

### 6.3 JSON export from a SwiftUI toolbar may create files during view rendering

`exportJSON(for:)` is called inside the `Menu` body. SwiftUI can rebuild body frequently. This can create temp files as a side effect of rendering.

Better pattern:

- prepare export file when user taps export,
- store URL in state,
- present share sheet.

### 6.4 Exports do not include source evidence meaningfully

Because source segment IDs are currently empty, exported action items/decisions/risks cannot be traced back.

### 6.5 No export validation evidence

`TASKS.md` says exported files were verified outside the app, but no test result is recorded in `TEST_PLAN.md`.

## New problems found

### 6.A Export may reflect internally inconsistent IDs

If transcript and analysis meeting IDs are wrong internally, exported JSON may look structured but contain inconsistent relationships.

### 6.B Export is too tied to currently loaded view state

If transcript or analysis fails to load in `MeetingDetailView`, export may omit artifacts that exist on disk.

A more robust export service should load from storage by meeting ID.

---

# Phase 7 — Chat MVP

## Expected goal

Basic provider-agnostic chat:

- chat conversation/message models,
- Chat UI,
- send through `AIProvider`,
- selected provider/model,
- basic message history.

## Current state

Partially implemented.

Implemented:

- `ChatConversationModel`.
- `ChatMessageModel`.
- `ChatListView`.
- `ChatView`.
- `ChatViewModel`.
- Message send through `ProviderRouter`.
- Basic chat bubbles.
- Basic message persistence.
- Basic error handling.

## What is still missing

### 7.1 No provider/model selection

Chat uses the first configured provider.

This does not satisfy “one selected provider/model” in a user-controlled way.

### 7.2 No local/remote/provider status in chat header

The UX manual expects chat to show provider/model/privacy context.

Current `ChatView` only shows conversation title.

### 7.3 No streaming

Streaming is not required for the first provider MVP, but provider configs expose `supportsStreaming`. Chat does not use it.

### 7.4 No retry failed message

If a provider call fails, there is no retry action for the user message.

### 7.5 No Markdown rendering

Assistant responses are rendered as plain text.

This is acceptable for minimal MVP but quickly becomes limiting.

### 7.6 No context selection

There is no way to chat with a meeting from the meeting detail screen yet. The spec includes “Ask questions about a meeting” as a main use case, but Phase 7 only implements general chat.

### 7.7 User message save may be inconsistent on provider failure

The user message is inserted into SwiftData before provider validation, but `context.save()` only happens after assistant response in the success path.

Depending on SwiftData autosave behavior, failed-provider user messages may be inconsistently persisted.

### 7.8 Conversation creation flow may be fragile from empty state

`ChatListView` uses `navigationDestination(item:)` only in the non-empty branch. Creating the first chat from the empty state inserts a conversation and sets `selectedConversation`, but navigation depends on the view recomputing into the non-empty branch quickly enough.

This may work, but it is fragile.

## New problems found

### 7.A Chat duplicates provider lookup logic

Both meeting analysis and chat fetch the first provider directly from SwiftData.

This should move to a provider selection/default provider service.

### 7.B Chat can send all history without limits

There is no context/window management, truncation, token estimate, or message limit.

---

# Phase 8 — iPhone 14 Plus Validation / MVP Hardening

## Expected goal

Make the core loop reliable on real iPhone 14 Plus:

- 5-minute recording,
- 15-minute recording,
- 60-minute recording,
- screen lock,
- interruption handling,
- provider failure,
- no-network behavior,
- user-facing errors,
- update test plan.

## Current state

Not complete.

`TASKS.md` correctly shows Phase 8 as unchecked.

`PROJECT_STATUS.md` says:

```text
Phase 7 — Complete. Next: Phase 8.
```

This is accurate.

But it also says:

```text
The MVP loop is fully functional.
```

That is too strong before real-device validation and before fixing the data consistency issues above.

## What is still missing

### 8.1 No real iPhone 14 Plus results

All Phase 8 tests remain open:

- 5-minute recording,
- 15-minute recording,
- 60-minute recording,
- screen lock,
- interruption,
- no network,
- provider failure,
- export.

### 8.2 No documented battery/thermal behavior

This is critical for a meeting recorder.

### 8.3 No audio route testing

Need test:

- iPhone microphone,
- AirPods/Bluetooth,
- speaker/mic changes,
- interruptions.

### 8.4 No long audio transcription test

Apple Speech may behave differently with long recordings. No test evidence yet.

### 8.5 No provider failure/no-network test evidence

The UI has basic errors, but the failure modes have not been tested.

### 8.6 No unit tests

The test plan lists candidate unit tests, but there are no actual test files.

## New problems found

### 8.A Current MVP claim is premature

The repo should say:

```text
Phase 7 implementation complete. MVP validation pending.
```

not:

```text
MVP fully functional.
```

### 8.B Hardening will uncover more issues because core data flow is inconsistent

Before testing 60-minute recordings, fix the meeting folder/audio/transcript/analysis ID flow. Otherwise test results may be confusing.

---

## 4. Cross-Cutting Missing Items

## 4.1 Real artifact repository layer

Right now, multiple views/services manually know where files are.

Recommended:

```text
MeetingRepository
  -> creates meeting
  -> owns meeting lifecycle
  -> coordinates FileArtifactStore
  -> deletes metadata + artifacts together
  -> loads transcript/analysis/audio by meeting ID
```

## 4.2 Processing pipeline state

There is no central state machine for:

```text
recorded -> transcribing -> transcribed -> analyzing -> analyzed
```

Individual screens mutate `meeting.status` directly.

This will become fragile as retry, import audio, and background processing are added.

## 4.3 Error model

Most errors are plain strings in view models.

Need typed user-facing errors with:

- technical reason,
- safe user message,
- retry action,
- severity.

## 4.4 Privacy UX is not actually connected

The UI/documents talk about local/remote transparency, but the app does not yet show per-meeting processing mode in a reliable way.

## 4.5 No import audio

Home shows `Import Audio`, but it is TODO.

This is okay if not MVP, but the button should either be hidden, disabled with explanation, or implemented.

## 4.6 No delete/cleanup flow

Deleting meetings/providers leaves artifacts/secrets behind.

## 4.7 No repository-level tests

The most valuable immediate tests are not UI tests. They are storage and parsing tests:

- create meeting folder,
- write audio placeholder,
- write/read transcript,
- write/read analysis,
- delete meeting cleans all artifacts,
- parse valid analysis JSON,
- fallback preserves raw response,
- provider request serialization.

## 4.8 No simulation/sample data mode

A sample meeting would allow UI and analysis review without real audio.

This would help development and QA.

---

## 5. Highest Priority Fixes Before Continuing

## Priority 1 — Fix meeting artifact lifecycle

Change recording flow so meeting ID exists before audio writing.

Target structure:

```text
Application Support/Meetings/{meetingId}/audio.m4a
Application Support/Meetings/{meetingId}/transcript.json
Application Support/Meetings/{meetingId}/analysis.json
Application Support/Meetings/{meetingId}/exports/
```

Remove the legacy fallback once migrated.

## Priority 2 — Fix transcript and analysis IDs

Ensure:

- transcript.meetingId = meeting.id,
- every segment.meetingId = meeting.id,
- analysis.meetingId = meeting.id,
- exported JSON has consistent IDs.

## Priority 3 — Fix source evidence mapping

Either use full UUIDs in prompts or implement stable short IDs.

Then map provider `source_segment_ids` back into domain objects.

## Priority 4 — Stop claiming raw response is preserved unless it is

Implement actual raw response artifact:

```text
provider.response.raw.txt
```

or change the docs and UI.

## Priority 5 — Add cleanup behavior

Deleting a meeting must delete its artifacts.

Deleting a provider must delete its Keychain secret.

## Priority 6 — Reconcile docs with reality

Change `PROJECT_STATUS.md` from:

```text
MVP loop fully functional
```

to:

```text
Phase 7 implementation complete. MVP validation and data-flow stabilization pending.
```

## Priority 7 — Confirm current build

Run Xcode build after all Phase 1–7 changes.

## Priority 8 — Start Phase 8 only after data-flow stabilization

Do not spend time testing 60-minute recordings until the artifact path and ID propagation are fixed.

---

## 6. Recommended New Stabilization Phase

Before Phase 8, add a new phase:

# Phase 7.5 — Data Flow Stabilization

Goal:

Make the implemented MVP loop internally consistent before real-device validation.

Tasks:

- Create meeting record at recording start.
- Store audio in per-meeting folder as `audio.m4a`.
- Remove legacy audio fallback after migration.
- Pass meeting ID into transcription engine or assign it after transcription.
- Ensure transcript and all segments use meeting ID.
- Ensure analysis uses meeting ID.
- Implement source segment ID mapping.
- Preserve raw provider response to file when parsing fails.
- Add meeting/provider deletion cleanup.
- Add basic unit tests for `FileArtifactStore`, exporters, and analysis parser.
- Update docs/status to reflect actual state.

Acceptance criteria:

- One meeting folder contains all artifacts.
- Transcript JSON references the correct meeting ID.
- Analysis JSON references the correct meeting ID.
- Export JSON is internally consistent.
- Deleting a meeting removes all related files.
- Analysis source IDs are not empty when provider returns them.
- Build succeeds.

---

## 7. Suggested Claude Code Prompt for the Next Step

Use this prompt before asking Claude to continue features:

```text
Read docs/IMPLEMENTATION_PLAN.md, docs/TASKS.md, docs/PROJECT_STATUS.md, and this audit document.

Do not add new product features.

Implement Phase 7.5: Data Flow Stabilization.

Focus only on:
1. creating the MeetingModel before recording starts,
2. saving audio under Application Support/Meetings/{meetingId}/audio.m4a,
3. ensuring transcript.meetingId and every TranscriptSegment.meetingId equal the MeetingModel.id,
4. ensuring MeetingAnalysis.meetingId equals the MeetingModel.id,
5. preserving raw provider responses as files when parsing fails,
6. making delete meeting/provider cleanup remove artifacts/secrets,
7. updating docs/TASKS.md and docs/PROJECT_STATUS.md honestly.

Do not implement WhisperKit, Calendar, Reminders, widgets, OCR, CloudKit, or new providers yet.
```

---

## 8. Final Assessment

The project has advanced significantly and is no longer just a shell. The implemented code now covers most pieces expected across Phases 1–7.

But the core product is a meeting recorder. For that kind of app, the critical question is not “do the screens exist?” It is:

> Can one meeting be captured, stored, transcribed, analyzed, exported, and later trusted as a coherent record?

At the moment, the answer is:

```text
Almost, but not yet.
```

The most serious blockers are:

1. audio file path mismatch,
2. meeting ID mismatch in transcripts/analysis,
3. source evidence not mapped,
4. raw provider response not truly preserved,
5. no cleanup of files/secrets,
6. Phase 8 not tested,
7. current implementation not committed cleanly.

Fix those before expanding the feature set.

