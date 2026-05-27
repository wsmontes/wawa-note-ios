# Wawa Note iOS — App Review with Focus on Import Mechanism

Reviewed archive: `wawa-note-ios.zip`  
Review focus: overall app health, with deeper analysis of audio/file import.

## 1. Executive Assessment

The project is becoming a real app, not just a shell. It now includes:

- SwiftUI app structure.
- Recording coordinator.
- Audio capture.
- Meeting artifact storage.
- Apple Speech and remote transcription engines.
- AI provider abstraction.
- Analysis pipeline.
- Export.
- Calendar view.
- Watch/watch-widget/share-extension targets.
- Brand assets and design documentation.

However, the current zip should **not** be considered stable or ready for Phase 8 validation yet.

The import mechanism exists now, which is a major improvement over the earlier state where `Import Audio` was only a placeholder. But the import mechanism is currently fragile and may not build cleanly. Even if build issues are fixed, the pipeline has architectural issues that will fail in real-world import scenarios.

My short assessment:

```text
Overall app direction: strong
Architecture ambition: high
Import feature maturity: prototype
Real-device readiness: not yet
Build confidence: low until fixed
```

The highest-priority fix is not UI polish. It is stabilizing the import/transcription path so imported files reliably become valid meetings.

---

## 2. Overall App Evaluation

## 2.1 What is good

The app has advanced significantly.

Good signs:

1. **Real product structure exists**
   - The app is separated into Audio, Domain, Providers, Storage, Transcription, UI, Ecosystem, Utilities.
   - This is much better than putting everything in `ContentView`.

2. **The app now has a broader ecosystem shape**
   - iOS app.
   - Share extension.
   - Watch app.
   - Watch widget.
   - Calendar layer.
   - Recording coordinator.
   - Brand assets.

3. **The artifact folder strategy is now clearer**
   - `FileArtifactStore` uses:

```text
Application Support/Meetings/{meetingId}/audio.m4a
```

   That is the right direction.

4. **Recording flow was improved**
   - `RecordingCoordinator` now creates a meeting before recording starts.
   - This fixes the earlier architectural problem where the audio file existed before the meeting identity existed.

5. **The Home screen has an Import Audio entry point**
   - This is aligned with the product requirement that the app should import existing audio files.

6. **The project has better provider UX**
   - There is an active provider manager.
   - There are provider templates.
   - API provider onboarding appears more mature than before.

## 2.2 What is concerning overall

### 2.2.1 The project is still not cleanly committed

`git status` shows many modified and untracked files.

The current zip includes major uncommitted changes such as:

- share extension,
- watch app,
- watch widget,
- audio import service,
- calendar layer,
- active provider manager,
- AI config service,
- modified project file,
- modified app files.

That makes the current state hard to trust as a reproducible milestone.

Recommendation:

```text
Fix build -> run smoke test -> commit as one named milestone
```

Suggested commit name:

```text
Implement import prototype and ecosystem integrations
```

or, better after fixes:

```text
Stabilize import pipeline and app integrations
```

### 2.2.2 The app probably does not compile right now

There are apparent compile blockers:

#### Problem A — `MeetingDetailViewModel` references `remoteEngine`, but no such property exists

File:

```text
wawa-note/UI/Meetings/MeetingDetailView.swift
```

Code area:

```swift
remoteEngine = RemoteTranscriptionEngine(baseURL: url, apiKey: apiKey)
```

There is no visible `remoteEngine` property in `MeetingDetailViewModel`.

#### Problem B — `MeetingDetailViewModel` references `transcriptionEngine.id`, but no such variable exists

File:

```text
wawa-note/UI/Meetings/MeetingDetailView.swift
```

Code area:

```swift
meeting.transcriptionEngineId = transcriptionEngine.id
```

The local variable is named `engine`, not `transcriptionEngine`.

Expected fix:

```swift
meeting.transcriptionEngineId = engine.id
```

#### Problem C — `AudioImportService` uses `UTType` but does not import `UniformTypeIdentifiers`

File:

```text
wawa-note/Domain/Services/AudioImportService.swift
```

Code area:

```swift
static let supportedUTTypes: [UTType] = [
```

The file imports:

```swift
import AVFoundation
import OSLog
```

but not:

```swift
import UniformTypeIdentifiers
```

#### Problem D — `AudioImportService` likely needs `AudioToolbox`

It uses:

```swift
ExtAudioFileRef
ExtAudioFileOpenURL
AudioStreamBasicDescription
ExtAudioFileGetProperty
ExtAudioFileCreateWithURL
AudioBufferList
AudioBuffer
```

Those are AudioToolbox/CoreAudio-level APIs. Relying on transitive imports from AVFoundation is risky.

Recommended imports:

```swift
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers
import OSLog
```

#### Problem E — `mData: &buffer` is suspicious

File:

```text
wawa-note/Domain/Services/AudioImportService.swift
```

Code area:

```swift
var buffer = [UInt8](repeating: 0, count: Int(bufferByteSize))

var fillBufferList = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
        mNumberChannels: channels,
        mDataByteSize: bufferByteSize,
        mData: &buffer
    )
)
```

`mData` expects a raw pointer. `&buffer` is not a raw pointer to the array storage in the way this API expects. This should be rewritten with `withUnsafeMutableBytes`.

This is another likely compile/runtime issue.

---

## 3. Import Mechanism — Current Flow

The intended import flow is now:

```text
HomeView
 -> fileImporter
 -> security-scoped URL
 -> copy file to temporaryDirectory
 -> AudioImportService.extractMetadata
 -> ImportFormView
 -> create MeetingModel
 -> convertToAAC
 -> save audio.m4a under meeting folder
 -> navigate to MeetingDetailView
 -> autoStartPipeline
 -> transcribe
 -> analyze
 -> display summary/transcript
```

That flow is directionally correct.

There is also a share-extension flow:

```text
Share extension receives file
 -> copy to App Group shared folder
 -> write filename to UserDefaults
 -> open wawanote://import
 -> HomeView.onOpenURL
 -> load pending file
 -> ImportFormView
 -> same import flow
```

This is also the right product direction.

The main problem: the implementation is currently too fragile for real-world files and provider setups.

---

## 4. Import Mechanism — What Works Conceptually

## 4.1 Security-scoped file copy is handled correctly

In `HomeView`, the file picked from iOS Files is copied to temporary storage while the security-scoped resource is still active.

This is good:

```swift
let didStart = url.startAccessingSecurityScopedResource()
defer { if didStart { url.stopAccessingSecurityScopedResource() } }

let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent(url.lastPathComponent)

try FileManager.default.copyItem(at: url, to: tempURL)
```

This avoids a common iOS bug where a file URL becomes inaccessible after the picker callback returns.

## 4.2 Imported meeting identity is created before writing the audio artifact

`RecordingCoordinator.createMeetingFromImport(...)` creates a `MeetingModel`, then `ImportFormView` writes audio to:

```swift
artifactStore.audioFileURL(for: meeting.id)
```

This is much better than the previous random-file approach.

## 4.3 The imported meeting moves into the normal meeting detail pipeline

After import, the app navigates to `MeetingDetailView`, which tries to auto-start transcription and analysis.

Product-wise, that is the right UX.

## 4.4 Share extension direction is good

Adding a share extension is the right move for this app.

Users will expect to import audio from:

- Voice Memos,
- Files,
- Messages,
- WhatsApp exports,
- email attachments,
- recordings from other apps.

A share extension makes that possible.

---

## 5. Import Mechanism — Critical Problems

## 5.1 Import conversion runs on the MainActor

`AudioImportService` is declared:

```swift
@MainActor
final class AudioImportService
```

That means `convertToAAC(...)` also runs on the main actor.

This is a serious issue.

The conversion loop reads and writes audio buffers:

```swift
while true {
    ExtAudioFileRead(...)
    ExtAudioFileWrite(...)
}
```

For a long meeting file, this can block the UI.

Impact:

- The import screen may freeze.
- The progress spinner may not animate.
- The user may think the app crashed.
- iOS may terminate the app if it becomes unresponsive.
- Large files become risky.

Recommendation:

Move heavy conversion work off the main actor.

Better structure:

```swift
final class AudioImportService: Sendable {
    func extractMetadata(url: URL) async throws -> ImportMetadata
    func convertToAAC(inputURL: URL, outputURL: URL) async throws
}
```

or isolate conversion in a dedicated actor:

```swift
actor AudioImportWorker {
    func convertToAAC(...) throws
}
```

UI updates should stay in `ImportFormView`; conversion should not.

---

## 5.2 Supported file types are broader than the actual converter supports

`AudioImportService.supportedUTTypes` includes:

```swift
.mpeg4Audio, .mp3, .wav, .aiff,
.mpeg4Movie, .quickTimeMovie, .movie
```

But the actual import implementation uses `AVAudioPlayer` for metadata and `ExtAudioFileOpenURL` for conversion.

That is okay for some audio files, but not reliable for movie containers.

Problem:

- `canRead(url:)` may accept a video file if it has a video track.
- `extractMetadata(url:)` then tries to open it with `AVAudioPlayer`.
- That may fail for `.mov` / `.mp4` video even if the video contains an audio track.
- `convertToAAC(...)` via `ExtAudioFileOpenURL` may also fail for movie containers.

Current `canRead` logic:

```swift
return asset.tracks(withMediaType: .audio).first != nil
    || asset.tracks(withMediaType: .video).first != nil
```

This accepts video-only files. That is not correct for an audio import pipeline.

Recommendation:

For MVP, remove movie support or implement proper audio extraction with `AVAssetReader` / `AVAssetExportSession`.

MVP-safe supported types:

```swift
.mpeg4Audio
.mp3
.wav
.aiff
```

Then later add:

```swift
.mpeg4Movie
.quickTimeMovie
.movie
```

only after implementing video-audio extraction.

---

## 5.3 Import should not always convert everything

The current import flow always does:

```swift
try await importService.convertToAAC(inputURL: sourceURL, outputURL: destURL)
```

That means even an already-good `.m4a` gets decoded/re-encoded.

Problems:

- Extra time.
- Quality loss.
- Higher battery usage.
- More opportunities to fail.
- Bad UX for large files.

Recommended approach:

```text
If source is already compatible M4A/AAC:
    copy into meeting folder as audio.m4a
Else:
    convert to AAC
```

Pseudo-flow:

```swift
if importService.isNativeM4ACompatible(sourceURL) {
    try artifactStore.copyAudioToMeeting(sourceURL: sourceURL, meetingId: meeting.id)
} else {
    try await importService.convertToAAC(inputURL: sourceURL, outputURL: destURL)
}
```

---

## 5.4 No progress reporting for import conversion

`ImportFormView` only shows:

```text
Converting...
```

There is no percentage, no file-size-aware progress, no phase label.

For a 60-minute meeting, this is weak.

Recommended states:

```text
Preparing file...
Reading audio...
Converting to app format...
Saving meeting...
Ready
```

Even if exact progress is hard, a staged progress view is better.

---

## 5.5 Imported meeting is created before conversion succeeds

Current flow:

```swift
let meeting = coordinator.createMeetingFromImport(...)
let destURL = artifactStore.audioFileURL(for: meeting.id)
try await importService.convertToAAC(...)
```

If conversion fails, the SwiftData meeting remains inserted.

Impact:

- The user may later see a meeting with no usable audio.
- The app can accumulate broken imported meetings.
- Meeting list becomes polluted.

Recommended fix:

Either:

1. Create meeting as `.importing`, and delete it on failure; or
2. Convert first to a staging file, then create the meeting only after conversion succeeds.

Best approach for reliability:

```text
Import staging folder
 -> validate/convert file
 -> create MeetingModel
 -> move/copy final audio into Meetings/{meetingId}/audio.m4a
 -> save MeetingModel as recorded
```

If you prefer preserving failed import attempts, then set:

```swift
meeting.status = .failed
```

and show a repair/retry option.

---

## 5.6 Temporary files are not cleaned up

File picker imports copy to:

```swift
FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
```

After successful import, the temp file is not removed.

Share-extension imports copy to:

```text
App Group/shared/{filename}
```

After successful import, the shared file is not removed.

Impact:

- Storage leak.
- Large audio files remain duplicated.
- Repeated imports can consume significant iPhone storage.

Recommendation:

After successful conversion/copy:

```swift
try? FileManager.default.removeItem(at: sourceURL)
```

only if the source is known to be app-owned temp/shared copy.

Do not delete original external files.

---

## 5.7 Share extension accepts too much

`wawa-note-share/Info.plist` uses:

```text
NSExtensionActivationRule = TRUEPREDICATE
```

That means the extension may appear for almost anything.

This is bad UX and risky.

Recommendation:

Restrict activation rule to audio/movie/file types.

At minimum, avoid appearing on unrelated content like plain text, URLs, photos, etc.

---

## 5.8 Share extension uses a single pending filename key

Current approach:

```swift
shared?.set(filename, forKey: "pendingImportFile")
```

This means only one pending import can exist.

Problems:

- If the user shares two files quickly, one can overwrite the other.
- There is no queue.
- There is no metadata.
- There is no unique import ID.
- Duplicate filenames can collide.

Better approach:

```text
pendingImports = [
  { id, filename, originalName, createdAt, sourceApp }
]
```

or at least write a UUID-prefixed filename.

Example:

```swift
let safeName = "\(UUID().uuidString)-\(filename)"
```

---

## 5.9 File names are not sanitized

The import flow uses `url.lastPathComponent` and suggested filenames directly.

Risk:

- Duplicate collisions.
- Weird characters.
- Very long filenames.
- Unexpected path-like names.
- Share extension overwrites existing shared file with the same name.

Recommendation:

Use a sanitizer:

```swift
func safeImportFilename(original: String) -> String {
    let base = original
      .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    return "\(UUID().uuidString)-\(base)"
}
```

---

## 5.10 Preview player is never initialized

`ImportFormView` has:

```swift
@State private var player: AVAudioPlayer?
```

and:

```swift
private var previewButton: some View {
    Button { togglePreview() } label: { ... }
        .disabled(player == nil)
}
```

But I do not see `player` being assigned.

There is an import service function:

```swift
func previewPlayer(for url: URL) -> AVAudioPlayer?
```

but the view does not call it.

Impact:

- Preview is always disabled.
- The UI shows a Preview section that does not work.

Recommended fix:

```swift
.onAppear {
    player = importService.previewPlayer(for: sourceURL)
}
```

For video files this may still fail, which is another reason to split audio/video handling.

---

## 5.11 The import pipeline chooses remote transcription too aggressively

In `MeetingDetailViewModel.transcribe(...)`, if any active provider exists with a base URL, the app chooses remote transcription:

```swift
if let config = ActiveProviderManager.shared.getActiveProvider(context: context),
   let baseURL = config.baseURL {
    engine = RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
} else {
    engine = localEngine
}
```

This is a major bug.

If the user has DeepSeek, Anthropic, Gemini, LM Studio, or an OpenAI-compatible chat provider configured, the app may try to send audio to:

```text
{baseURL}/audio/transcriptions
```

But many of those providers do not support audio transcription.

Examples:

- DeepSeek chat API: likely no Whisper endpoint.
- LM Studio: usually no `/audio/transcriptions`.
- Ollama: no OpenAI Whisper endpoint by default.
- Anthropic: not OpenAI-compatible transcription.
- Gemini endpoint format is different.

Impact:

- Imported audio opens meeting detail.
- Auto pipeline starts.
- It chooses wrong remote transcription engine.
- Transcription fails.
- User blames import even though import file was saved.

Recommendation:

Transcription engine selection must be separate from analysis provider selection.

Correct logic:

```text
If user selected transcription engine == Apple Speech:
    use AppleSpeechTranscriptionEngine
Else if selected transcription provider supports audioTranscription:
    use RemoteTranscriptionEngine
Else:
    use AppleSpeechTranscriptionEngine
```

Use `config.supportsAudio == true` at minimum.

Even better: use feature config:

```json
"transcription": {
  "engine": "apple-speech",
  "fallbackEngine": "remote-whisper",
  "provider": "openai",
  "model": "whisper-1"
}
```

Do not derive transcription provider from the active chat/analysis provider.

---

## 5.12 Remote transcription endpoint is hardcoded

Remote transcription builds endpoint as:

```swift
baseURL.absoluteString + "/audio/transcriptions"
```

This ignores `ai_config.json`, which already defines provider endpoints.

Problem:

- OpenAI: works if baseURL is `https://api.openai.com/v1`.
- Trailing slash can produce double slash.
- Local providers may not support this.
- Gemini uses a different API shape.
- Anthropic uses a different API shape.
- DeepSeek does not support it.

Recommendation:

Use provider endpoint config, not hardcoded path.

At minimum:

```swift
baseURL.appendingPathComponent("audio/transcriptions")
```

But better:

```swift
config.endpoint("audioTranscription")
```

---

## 5.13 Import creates an imported meeting, but provenance is not stored

`MeetingModel` has:

```swift
var isImported: Bool?
var importSourceURL: String?
```

But `createMeetingFromImport(...)` sets only:

```swift
isImported: true
```

It does not store:

- original filename,
- source format,
- original file size,
- import date,
- whether conversion was performed,
- original source app,
- whether source was file picker or share extension.

That metadata will be useful for debugging and user trust.

Recommended fields:

```swift
var importOriginalFilename: String?
var importOriginalFormat: String?
var importOriginalFileSize: Int64?
var importDate: Date?
var importWasConverted: Bool
var importSource: String? // filePicker / shareExtension
```

---

## 5.14 Import does not ask about transcription mode

After import, the pipeline auto-starts transcription.

This may be okay for MVP, but it creates privacy risk if the app chooses remote transcription.

Recommended UX:

For imported files, show:

```text
Audio imported.
How do you want to transcribe it?

[Apple Speech — on this iPhone]
[Remote Whisper — sends audio to provider]
```

If you want less friction, default to Apple/local.

---

## 6. Import UX Evaluation

## 6.1 What is good

The UX is simple:

- Home has `Import Audio`.
- File picker opens.
- Metadata confirmation appears.
- User can edit title and date.
- User sees duration, format, size.
- Import creates a meeting and navigates to detail.

That is the right high-level flow.

## 6.2 What is missing

### 6.2.1 The preview section is non-functional

As noted, the player is never initialized.

### 6.2.2 “Converting...” is too vague

For large files, users need stronger feedback.

### 6.2.3 No privacy explanation

The import form does not say whether the imported audio stays local or may be sent to remote transcription.

Given the app’s privacy-first direction, this is important.

### 6.2.4 No failure recovery

If conversion fails after meeting creation, the user sees an error, but there is no clear cleanup or retry.

### 6.2.5 No file type education

If the file is unsupported, the message says convert to MP3 or M4A. That is okay, but the app itself claims MP4/MOV support. The UX and actual support disagree.

---

## 7. App as a Whole — Missing / Regressed Items

## 7.1 Chat tab is missing from `ContentView`

`ContentView` currently has:

```swift
Home
Meetings
Settings
```

The previous MVP information architecture included:

```text
Home
Meetings
Chat
Settings
```

There are chat files in the project:

```text
UI/Chat/ChatListView.swift
UI/Chat/ChatView.swift
UI/Chat/ChatViewModel.swift
```

But they are not exposed in the tab shell.

Recommendation:

Add the Chat tab back or explicitly decide chat is deferred.

## 7.2 Meetings tab nests NavigationStacks

`ContentView` has a TabView. `MeetingsTabView` creates `NavigationStack`, and `MeetingsListView` also creates another `NavigationStack`.

Nested navigation stacks can produce odd navigation behavior.

Recommendation:

Only one navigation stack per tab.

## 7.3 Calendar and Watch features are premature

Calendar, watch app, widget, share extension, and lock screen/Now Playing controls are all useful eventually. But they increase complexity before the core import/record/transcribe/analyze loop is validated.

Recommendation:

Do not expand these further until import and core meeting loop are stable.

## 7.4 Docs are now partly stale

`PROJECT_STATUS.md` says:

```text
import audio button is TODO.
```

But import now exists.

`TASKS.md` still shows:

```text
- [ ] Import audio files.
```

This should be updated, but honestly:

```text
- [~] Import audio files — prototype implemented; stabilization required.
```

---

## 8. Highest Priority Fixes

## P0 — Build blockers

Fix these first:

1. Add missing imports in `AudioImportService.swift`:

```swift
import UniformTypeIdentifiers
import AudioToolbox
```

2. Remove or define `remoteEngine` in `MeetingDetailViewModel`.

3. Replace:

```swift
meeting.transcriptionEngineId = transcriptionEngine.id
```

with:

```swift
meeting.transcriptionEngineId = engine.id
```

4. Fix `AudioBuffer.mData` construction using `withUnsafeMutableBytes`.

5. Run a real Xcode build.

## P1 — Import correctness

1. Move conversion off `@MainActor`.
2. Clean temp/shared files after success.
3. Do not create a permanent meeting until conversion succeeds, or mark failed imports clearly.
4. Remove video UTTypes until proper audio extraction from video is implemented.
5. Initialize preview player.
6. Sanitize filenames and avoid collisions.
7. Track import provenance metadata.

## P1 — Transcription selection

1. Do not use active chat/analysis provider for transcription automatically.
2. Use Apple Speech by default for imported audio.
3. Use remote transcription only if explicitly selected and provider supports it.
4. Use `ai_config.json` transcription provider/endpoint instead of hardcoded provider logic.

## P2 — Share extension reliability

1. Restrict `NSExtensionActivationRule`.
2. Use queue/UUID for pending imports.
3. Clean shared files after import.
4. Store metadata for share-origin imports.
5. Avoid fragile app-opening logic if it causes App Store or runtime issues.

## P2 — UX polish

1. Add staged import progress.
2. Add privacy note on Import screen.
3. Make unsupported-format messages match real supported types.
4. Show retry/recover if conversion fails.
5. Show “Imported” badge in meeting detail/list.

---

## 9. Recommended Import Architecture

I recommend splitting import into these layers:

```text
ImportPicker
  -> gets external URL

ImportStagingService
  -> copies security-scoped/shared file to app-owned staging folder
  -> sanitizes filename
  -> extracts metadata

ImportPreparationView
  -> title/date/transcription mode/preview

AudioImportProcessor
  -> validates file
  -> copies compatible files directly
  -> converts incompatible audio files
  -> extracts audio from video only when implemented
  -> reports progress

MeetingImportCoordinator
  -> creates meeting after successful staging/conversion
  -> moves audio to Meetings/{meetingId}/audio.m4a
  -> stores import provenance
  -> triggers optional transcription
```

Final artifact layout:

```text
Application Support/
  ImportStaging/
    {importId}/source
    {importId}/converted.m4a

  Meetings/
    {meetingId}/
      audio.m4a
      transcript.json
      analysis.json
      provider.response.raw.txt
      exports/
```

Happy path:

```text
Pick/share file
 -> copy to staging
 -> metadata
 -> user confirms
 -> convert/copy to final audio
 -> create MeetingModel
 -> delete staging
 -> open MeetingDetail
 -> local transcription by default
```

This is more robust than creating the meeting before conversion.

---

## 10. Suggested Claude Code Prompt

Use this prompt next:

```text
Read the import audit document.

Do not add new product features.

Fix the import mechanism and build blockers only.

Tasks:
1. Fix compile issues in MeetingDetailViewModel:
   - remove/define remoteEngine
   - replace transcriptionEngine.id with engine.id
2. Fix AudioImportService imports:
   - add UniformTypeIdentifiers
   - add AudioToolbox if needed
3. Move audio conversion off MainActor.
4. Fix ExtAudioFile buffer handling using withUnsafeMutableBytes.
5. Restrict supported imported file types to actual working audio formats for now: M4A, MP3, WAV, AIFF.
6. Initialize preview player in ImportFormView.
7. Clean temporary and App Group shared files after successful import.
8. Do not auto-select remote transcription just because an AI provider exists.
   Default imported audio transcription to Apple Speech unless a transcription-capable remote provider is explicitly selected.
9. If conversion fails after creating a meeting, delete the meeting and its artifacts or mark it failed.
10. Update docs/TASKS.md and docs/PROJECT_STATUS.md to say import is prototype/stabilizing, not fully validated.

After changes, run an Xcode build and report exact results.
```

---

## 11. Final Verdict

The app as a whole is moving in the right direction. It has the bones of the intended product.

But the import mechanism is currently a prototype with real risks:

```text
Import exists, but is not robust yet.
```

The three most serious issues are:

1. likely build blockers in `MeetingDetailView` and `AudioImportService`;
2. conversion running on the main actor;
3. remote transcription being selected based on the active AI provider instead of a real transcription capability.

Fix those before testing long imports or adding new features.

The correct next phase is:

```text
Import Stabilization
```

not:

```text
More ecosystem features
```
