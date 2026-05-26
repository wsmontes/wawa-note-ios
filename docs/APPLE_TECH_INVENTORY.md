# Apple Ecosystem Technical Inventory for iPhone 14 Plus

Companion document for: **AI Meeting Companion / Universal AI Client for iPhone**

Research snapshot: **2026-05-25**

Target test device: **iPhone 14 Plus**

---

## 1. Purpose of This Document

This document maps the Apple/iOS technologies that can be useful for the AI Meeting Companion project.

The goal is not just to list Apple frameworks. The goal is to decide what each technology can realistically contribute to the product, especially considering that the first physical test device is an **iPhone 14 Plus**.

The app vision depends on several technical areas:

- Audio capture.
- Live or offline transcription.
- Local AI and machine learning.
- Remote AI provider integration.
- Secure storage of API keys and meeting data.
- Local search and project memory.
- Export and sharing.
- Siri, Shortcuts, Calendar, Reminders, and other Apple ecosystem integrations.
- Background execution and long-running meeting workflows.

---

## 2. iPhone 14 Plus Baseline

## 2.1 Device Profile

The iPhone 14 Plus is a strong enough target for the first prototype.

Relevant characteristics:

- A15 Bionic chip.
- 6-core CPU.
- 5-core GPU.
- 16-core Neural Engine.
- Large 6.7-inch display.
- Good battery life for long recording sessions.
- Face ID.
- Lightning connector.
- Microphone and audio stack suitable for meeting recording.
- Bluetooth 5.x generation hardware.
- NFC support.
- Local storage options depending on device capacity.

## 2.2 Practical Meaning for This App

The iPhone 14 Plus should be good for:

- Native audio recording.
- Apple native speech recognition.
- Local Whisper-style transcription with small or medium models, subject to testing.
- Core ML inference for classification, entity extraction helpers, embeddings, or small task-specific models.
- Local semantic/full-text search.
- Secure API-key storage.
- Offline meeting archive.
- Provider-agnostic remote API calls.
- Basic local-first workflows.

The iPhone 14 Plus is probably not ideal for:

- Large local LLMs with comfortable performance.
- Long-context local generative reasoning.
- Heavy multi-model pipelines running continuously during a meeting.
- Relying on Apple Foundation Models / Apple Intelligence APIs.

## 2.3 Important Constraint: Apple Intelligence

The iPhone 14 Plus should be treated as **not Apple Intelligence-capable**.

This matters because Apple’s Foundation Models framework depends on Apple Intelligence availability. For this project, that means:

- Do not make Apple Foundation Models part of MVP 1.
- Do not assume on-device Apple LLM access on the iPhone 14 Plus.
- Keep AppleLocalProvider as a future/conditional provider.
- Build the app so it can use Apple Foundation Models on newer devices later.
- For iPhone 14 Plus, local intelligence should focus on Core ML, Natural Language, Vision, Sound Analysis, Speech, and third-party local engines such as WhisperKit.

Recommended implementation rule:

```text
Apple Foundation Models = optional runtime capability, not a baseline dependency.
```

---

## 3. Recommended Technology Strategy

## 3.1 Best Initial Stack

For the first working version on iPhone 14 Plus:

```text
SwiftUI
SwiftData or SQLite/Core Data
AVFoundation / AVFAudio
Speech framework / SpeechAnalyzer where available
URLSession
Keychain Services
OpenAI-compatible provider adapter
Markdown/JSON export
```

## 3.2 Best Second Layer

After MVP is working:

```text
WhisperKit or whisper.cpp/Core ML
Natural Language framework
Core Spotlight
Sound Analysis
EventKit
App Intents / Shortcuts
CloudKit optional sync
CryptoKit for local encryption
```

## 3.3 Best Future Layer

For later iterations:

```text
Apple Foundation Models on supported devices
Local embeddings
Project-level semantic memory
Speaker diarization
Calendar-aware meeting intelligence
Live Activities
Widgets
Watch quick recorder
Mac companion app
```

---

## 4. Audio and Meeting Capture

## 4.1 AVFoundation / AVFAudio

### Role in the project

This is the core Apple technology for meeting recording.

Use it for:

- Capturing microphone audio.
- Saving audio files.
- Monitoring audio levels.
- Managing audio routes.
- Handling interruptions.
- Playing back recorded meetings.
- Jumping playback to transcript timestamps.
- Feeding audio buffers to transcription engines.

Relevant classes/concepts:

- `AVAudioSession`
- `AVAudioEngine`
- `AVAudioRecorder`
- `AVAudioPlayer`
- `AVAsset`
- `AVAssetWriter`
- `AVAudioPCMBuffer`
- `AVAudioFormat`

### Recommended use

Use **AVAudioEngine** for anything that needs live buffers.

Use **AVAudioRecorder** only if the initial MVP is very simple and just needs record-to-file.

For this app, the better architecture is:

```text
AVAudioEngine
  -> local file writer
  -> live waveform/level meter
  -> transcription buffer stream
  -> optional sound analysis stream
```

### Product features enabled

- Meeting recording.
- Live transcription pipeline.
- Audio waveform.
- Silence detection.
- Timestamp alignment.
- Audio playback by transcript segment.
- Input monitoring.

### Recommendation

Use AVFoundation from MVP 1.

---

## 4.2 AVAudioSession

### Role in the project

Controls how the app interacts with iPhone audio hardware and other audio apps.

Important for:

- Asking for microphone access.
- Choosing audio category.
- Handling Bluetooth microphone input.
- Handling audio interruptions.
- Keeping audio stable when the screen locks or app state changes.

### Recommended categories to test

Potential categories/modes:

```swift
AVAudioSession.Category.record
AVAudioSession.Category.playAndRecord
AVAudioSession.Mode.measurement
AVAudioSession.Mode.spokenAudio
```

Need empirical testing because meeting recording, speech recognition, playback, Bluetooth routing, and background behavior may interact differently.

### Product features enabled

- Better recording reliability.
- Cleaner audio input.
- External mic support.
- Bluetooth headset/mic experiments.
- Meeting recording while viewing transcript.

### Recommendation

Create a dedicated `AudioSessionManager` early. Do not spread `AVAudioSession` calls across UI views.

---

## 4.3 Background Audio and Background Execution

### Role in the project

Meetings can be long. The app must survive screen lock, interruptions, and limited background windows.

Apple provides background capabilities, but iOS is strict. This project should not assume unlimited background computation.

### Use cases

- Continue recording when the screen locks.
- Continue audio playback in background.
- Finish short post-processing tasks after meeting ends.
- Schedule non-urgent cleanup or indexing later.

### Recommended approach

For MVP:

- Focus on stable foreground recording first.
- Then test screen-lock behavior.
- Add background audio mode only if needed and justified by actual recording behavior.
- Use BackgroundTasks for maintenance, not for heavy live transcription assumptions.

### Product risk

Long-running background transcription and analysis may be constrained. The app should save audio first, then process when active if needed.

Recommended fallback:

```text
If live analysis stops, recording should continue or at least save audio safely.
If analysis cannot run in background, resume processing when the app returns to foreground.
```

---

## 5. Speech-to-Text Options

## 5.1 Speech Framework — SFSpeechRecognizer

### Role in the project

Apple's classic speech recognition API.

Use it for:

- Live dictation.
- Transcribing recorded audio.
- Testing native transcription quickly.
- MVP implementation before integrating WhisperKit.

### Strengths

- Native Apple framework.
- Good integration with iOS permissions.
- Easy to prototype.
- Works with live or prerecorded audio.
- Can return partial results.

### Weaknesses

- May depend on language/device/service availability.
- Not designed as a full meeting-intelligence system.
- Speaker diarization is not the core feature.
- Long-form meeting behavior must be tested.

### Recommendation

Use for MVP 1 if SpeechAnalyzer is not stable enough in the deployment target.

---

## 5.2 SpeechAnalyzer / SpeechTranscriber

### Role in the project

Modern Apple speech-to-text path introduced for newer iOS versions.

This is more aligned with long-form speech, meetings, lectures, and conversational transcription.

### Why it matters

The product is specifically about meetings. A speech API designed around longer conversation is a better fit than a dictation-oriented approach.

### Use cases

- Live transcription.
- Long-form speech transcription.
- Conversation transcription.
- Possibly better chunking and modern async workflows.

### Recommendation

Investigate immediately if your Xcode/iOS target supports it.

Suggested strategy:

```text
TranscriptionEngine protocol
 ├── AppleSpeechRecognizerEngine
 ├── AppleSpeechAnalyzerEngine
 ├── WhisperKitEngine
 └── RemoteTranscriptionEngine
```

This allows the app to run on different iOS versions and devices without rewriting the app.

---

## 5.3 WhisperKit

### Role in the project

Local Whisper-based transcription optimized for Apple platforms.

Use it for:

- Offline transcription.
- Privacy-first mode.
- Better control over model selection.
- Potentially better meeting transcription than older native APIs.
- Future speaker-related extensions depending on SDK capabilities.

### Strengths

- On-device speech-to-text.
- Swift-friendly path.
- Core ML-oriented design.
- Good conceptual fit for privacy-first meetings.

### Risks

- Model size and memory pressure on iPhone 14 Plus.
- Battery drain during long meetings.
- Live transcription stability must be tested.
- Model download/storage management must be designed.
- Larger models may be impractical on this device.

### Recommendation

Make WhisperKit part of MVP 3, not MVP 1.

Testing priority:

1. tiny/base model on short audio.
2. small model on 10-minute meeting.
3. longer 45-60 minute recording.
4. battery and heat check.
5. transcript quality with domain-specific glossary terms.

---

## 5.4 whisper.cpp with Core ML

### Role in the project

Alternative local Whisper path using C/C++ engine with Core ML acceleration for the encoder.

### Strengths

- Mature ecosystem.
- Can be fast with Core ML acceleration.
- Lower-level control.
- Useful if WhisperKit is too opinionated.

### Weaknesses

- More integration work in a SwiftUI app.
- More manual model management.
- More build complexity.
- More potential friction with App Store packaging.

### Recommendation

Keep as fallback/research option. Prefer WhisperKit first for a native Swift project.

---

## 6. Local Machine Learning and AI

## 6.1 Core ML

### Role in the project

Main Apple framework for running ML models locally on-device.

Use it for:

- Audio classification.
- Text classification.
- Embeddings.
- Entity classification.
- Intent detection.
- Small summarization helpers if model is available.
- Whisper-related models.
- Custom models trained outside the app and converted to Core ML.

### Product features enabled

- Offline classifiers.
- Privacy-preserving pre-processing.
- Local intent detection.
- Local meeting segment scoring.
- Local topic/category detection.
- Local quality checks.
- Local noise/silence classifiers.

### Recommended use

Do not start with a large local LLM.

Start with small, useful local models:

- “Does this segment contain an action item?”
- “Does this segment contain a decision?”
- “Is this segment irrelevant small talk?”
- “What language is this segment?”
- “Does this segment mention a date?”

### Recommendation

Core ML should be a core long-term pillar, but used surgically at first.

---

## 6.2 Natural Language Framework

### Role in the project

Apple framework for local NLP tasks.

Use it for:

- Language identification.
- Tokenization.
- Lemmatization.
- Named entity recognition.
- People/place/organization extraction.
- Basic linguistic tagging.
- Pre-processing before LLM analysis.

### Product features enabled

- Detect meeting language.
- Extract candidate people/organizations locally.
- Help build entity list before sending transcript to API.
- Improve search filters.
- Support local lightweight analysis on iPhone 14 Plus.

### Recommendation

Use early. It is lightweight and useful.

Possible service:

```swift
final class LocalNLPService {
    func detectLanguage(_ text: String) -> String?
    func extractEntities(_ text: String) -> [EntityCandidate]
    func tokenize(_ text: String) -> [String]
}
```

---

## 6.3 Foundation Models Framework

### Role in the project

Apple's framework for accessing the on-device language model behind Apple Intelligence.

### Fit for this project

Conceptually excellent:

- On-device summaries.
- Local extraction.
- Local rewriting.
- Structured output.
- Privacy-first meeting analysis.

### iPhone 14 Plus constraint

This should not be treated as available on the iPhone 14 Plus.

### Recommendation

Design the provider abstraction so this can be plugged in later:

```swift
AppleFoundationModelProvider: AIProvider
```

But for this device:

```text
Feature flag: disabled / unavailable
Fallback: remote provider or local smaller Core ML tools
```

---

## 6.4 Accelerate, Metal, and Metal Performance Shaders

### Role in the project

Useful for optimized computation, vector math, signal processing, and advanced local model work.

Use cases:

- Audio pre-processing.
- Signal analysis.
- Embedding similarity search.
- Local vector operations.
- Model acceleration in lower-level custom paths.

### Recommendation

Do not use directly in MVP unless needed. Many libraries already use these under the hood.

Possible later use:

```text
Local vector search / similarity scoring for meeting memory.
```

---

## 7. Audio Intelligence Beyond Transcription

## 7.1 Sound Analysis Framework

### Role in the project

Apple framework for classifying sounds from audio files or live audio streams.

Use it for:

- Detecting laughter.
- Detecting applause.
- Detecting silence/noise patterns.
- Detecting non-speech audio events.
- Possibly separating speech-heavy parts from irrelevant audio.

### Product features enabled

- Meeting quality indicators.
- “This recording has too much background noise.”
- Segment timeline markers.
- Silence/non-speech skipping.
- Optional meeting mood signals.

### Recommendation

Useful, but not MVP-critical.

Add after transcription works.

---

## 7.2 Voice Activity Detection

### Role in the project

Detect whether audio contains speech.

Could be implemented with:

- SpeechAnalyzer modules where available.
- Sound Analysis.
- Custom Core ML model.
- Lightweight DSP thresholding.

### Product features enabled

- Avoid sending silence to transcription.
- Split audio into speech chunks.
- Improve battery usage.
- Improve cost if using remote transcription.

### Recommendation

Important for real meeting performance. Add after basic recording/transcription.

---

## 8. Vision, OCR, and Document Intelligence

## 8.1 Vision Framework

### Role in the project

Apple's computer vision framework.

Use it for:

- OCR from images.
- Extracting text from screenshots.
- Reading whiteboard photos.
- Reading meeting slides photographed from the room.
- Detecting document regions.

### Product features enabled

- Attach photo of whiteboard → extract text.
- Attach screenshot → summarize content.
- Add slide photo to meeting context.
- Build multimodal meeting notes without a full cloud vision model.

### Recommendation

Not MVP 1, but very valuable for meeting companion workflows.

Suggested feature:

```text
Add Photo to Meeting Context
  -> Vision OCR
  -> attach extracted text to meeting analysis
```

---

## 8.2 Live Text Style OCR via Vision

### Role in the project

On-device OCR can support privacy-friendly document capture.

Use cases:

- Whiteboard notes.
- Printed agendas.
- Sticky notes.
- Screenshots.
- Conference-room display photos.

### Recommendation

Add as a practical differentiator later. It is more valuable than generic image AI for this app.

---

## 9. Storage and Data Management

## 9.1 SwiftData

### Role in the project

Modern Swift-native persistence framework.

Use it for:

- Meeting metadata.
- Transcript segment metadata.
- Analysis records.
- Provider configurations excluding secrets.
- Project records.
- Tags.
- User preferences.

### Strengths

- Swift-native.
- Good with SwiftUI.
- Less boilerplate than Core Data.
- Good for structured app data.

### Risks

- Less mature than Core Data.
- Migration behavior must be tested.
- For large transcript-heavy data, raw files plus metadata may be safer.

### Recommendation

Use SwiftData for structured metadata if targeting iOS 17+.

Do not store large audio blobs directly in SwiftData.

---

## 9.2 Core Data

### Role in the project

Mature persistence framework.

Use it if:

- You need more proven migration behavior.
- You want mature tooling.
- You expect complex relationships and large stores.
- You prefer battle-tested persistence over newer SwiftData ergonomics.

### Recommendation

Either SwiftData or Core Data is fine. For this project, SwiftData is more pleasant unless migrations become a problem.

---

## 9.3 FileManager and Local Files

### Role in the project

Use the filesystem for larger artifacts.

Store as files:

- Audio recordings.
- Exported Markdown.
- Exported JSON.
- Transcript snapshots.
- Imported attachments.
- Whisper/Core ML model files.

Recommended folder structure:

```text
Application Support/
  Meetings/
    {meetingId}/
      audio.m4a
      transcript.original.json
      transcript.edited.json
      analysis.latest.json
      exports/
        summary.md
        meeting.json
  Models/
    WhisperKit/
  ProviderConfigs/
```

### Recommendation

Use database for index/metadata. Use files for large content.

---

## 9.4 CloudKit and iCloud

### Role in the project

Optional sync layer across Apple devices.

Use it for:

- Syncing meeting metadata.
- Syncing transcript text.
- Syncing summaries.
- Syncing project organization.
- Possibly syncing encrypted blobs.

### Caution

For privacy-first design, do not automatically sync raw audio to iCloud unless explicitly enabled.

### Recommendation

Not MVP 1.

Add only after local storage model is stable.

Possible modes:

```text
Local only
Sync metadata only
Sync transcript and summary
Sync everything including audio
```

---

## 9.5 Core Spotlight

### Role in the project

Allows meeting content to be indexed and searchable on device.

Use it for:

- Searching meetings from Spotlight.
- Private local indexing.
- Finding meeting summaries by natural language.
- Surfacing meeting records outside the app.

### Product features enabled

- Search “deployment date discussion” from Spotlight.
- Open directly into the meeting.
- Local discoverability without remote search.

### Recommendation

Very interesting for v2/v3. It aligns well with the local-first philosophy.

---

## 10. Security and Privacy

## 10.1 Keychain Services

### Role in the project

Secure storage for secrets.

Use it for:

- API keys.
- Provider tokens.
- Refresh tokens if OAuth is added.
- Encryption keys.
- Local unlock secrets.

### Recommendation

Use from MVP 1.

Never store API keys in SwiftData, UserDefaults, JSON files, or plain local config.

---

## 10.2 LocalAuthentication

### Role in the project

Face ID/passcode gate for sensitive app access.

Use it for:

- Unlocking app.
- Unlocking meeting archive.
- Unlocking API key settings.
- Unlocking sensitive project folders.

### Product features enabled

- “Require Face ID to open meeting archive.”
- “Require Face ID before showing API keys.”
- “Require Face ID before exporting a meeting.”

### Recommendation

Add after MVP 1 or early if sensitive meetings are expected.

---

## 10.3 CryptoKit

### Role in the project

Modern Swift crypto framework.

Use it for:

- Encrypting exported files.
- Encrypting local meeting archives.
- Generating hashes for audio/transcript versioning.
- Signing metadata.
- Deriving identifiers without leaking content.

### Recommendation

For MVP, rely on iOS app sandbox + Keychain for API keys.

For privacy mode v2, add optional per-meeting encryption:

```text
MeetingEncryptionService
  -> generate symmetric key
  -> store key in Keychain
  -> encrypt audio/transcript/analysis files
```

---

## 10.4 App Privacy Permissions

The app will need permission descriptions for:

- Microphone.
- Speech recognition.
- Local network, if connecting to LM Studio/Ollama on LAN.
- Contacts, if associating speakers with contacts.
- Calendar/Reminders, if generating follow-up events/tasks.
- Photos, if importing whiteboard/screenshot images.

Recommendation:

Write permission prompts in direct, specific language. The user should understand what happens locally and what can be sent to providers.

---

## 11. Networking and Provider Integration

## 11.1 URLSession

### Role in the project

Primary HTTP client for remote AI providers.

Use it for:

- Chat completions.
- Streaming responses.
- Remote transcription uploads.
- Provider model list fetches.
- API health checks.
- Downloading model assets if needed.

### Recommendation

Use from MVP 1.

Create a provider-agnostic networking layer:

```swift
protocol HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error>
}
```

---

## 11.2 Network Framework

### Role in the project

Lower-level networking for custom TCP/UDP/TLS flows.

Use it for:

- Local provider discovery.
- Custom streaming protocols.
- More control over local network connections.
- Possible future peer-to-peer sync.

### Recommendation

Not needed for the first remote API integration. Use URLSession first.

---

## 11.3 Bonjour

### Role in the project

Zero-configuration service discovery on local network.

Use it for:

- Discovering LM Studio/Ollama helper server on Mac.
- Discovering local transcription server.
- Discovering a future Mac companion app.

### Product feature

Instead of typing:

```text
http://192.168.1.25:1234/v1
```

The app could show:

```text
Found local AI server: Wagner's MacBook Pro
```

### Recommendation

Add after manual local provider URL works.

---

## 11.4 Local Network Privacy

### Role in the project

iOS requires explicit local network permission when apps interact with local network services.

Use case:

- Connecting iPhone app to LM Studio running on Mac.
- Discovering local AI provider via Bonjour.

### Recommendation

Add clear local network permission copy:

```text
This app uses your local network to connect to AI providers running on your own devices, such as LM Studio or Ollama on your Mac.
```

---

## 11.5 Multipeer Connectivity

### Role in the project

Peer-to-peer Apple device communication.

Use it for:

- iPhone ↔ iPad companion workflows.
- iPhone ↔ Mac companion sync.
- Nearby device handoff experiments.
- Offline transfer of meeting notes.

### Recommendation

Interesting, but not needed in MVP.

Bonjour + URLSession is more practical for local AI server discovery.

---

## 12. Bluetooth, NFC, and Peripheral Integration

## 12.1 Core Bluetooth

### Role in the project

Communicate with Bluetooth Low Energy peripherals.

Possible use cases:

- External meeting button.
- BLE microphone accessory metadata.
- Hardware marker button.
- Nearby device control.
- Future wearable meeting controller.

### Recommendation

Not necessary for MVP.

But useful for later “physical meeting marker” idea:

```text
Press BLE button -> add timestamp marker: Important
```

---

## 12.2 Core NFC

### Role in the project

Read NFC tags.

Possible use cases:

- Tap an NFC tag in a meeting room to start a project-specific meeting.
- Tap a tag on a notebook to associate the meeting with a project.
- Tap a personal NFC card to identify a participant.

### Recommendation

Nice future workflow, not core.

---

## 13. Apple Ecosystem Integrations

## 13.1 EventKit — Calendar and Reminders

### Role in the project

Access Calendar and Reminders with user permission.

Use it for:

- Associating a recording with a calendar event.
- Pulling meeting title, attendees, and time.
- Creating follow-up meetings.
- Creating reminders from action items.

### Product features enabled

- “This recording belongs to the 10:00 AM GLPR meeting.”
- “Create reminders from action items.”
- “Schedule follow-up with attendees.”

### Recommendation

Very valuable for v2.

For MVP, allow manual meeting title/project. Add Calendar later.

---

## 13.2 Contacts Framework

### Role in the project

Access user contacts with permission.

Use it for:

- Matching speaker names to people.
- Email follow-up recipients.
- Meeting participant metadata.
- Contact-aware summaries.

### Recommendation

Useful only after Calendar/EventKit or manual participant lists exist.

Do not start here.

---

## 13.3 App Intents and Shortcuts

### Role in the project

Expose app actions to Siri, Shortcuts, Spotlight, and system surfaces.

Use it for:

- Start meeting recording.
- Stop meeting recording.
- Create meeting summary.
- Ask latest meeting question.
- Create task from latest action items.
- Export latest summary.

### Product features enabled

- “Hey Siri, start a meeting recording in Meeting AI.”
- Shortcut automation after calendar event starts.
- Action button integration on supported devices.
- Spotlight actions.

### iPhone 14 Plus note

No Action Button on iPhone 14 Plus, but Shortcuts/Siri-style integrations can still be relevant depending on OS support.

### Recommendation

Add after core recording flow is stable.

---

## 13.4 SiriKit

### Role in the project

Older Siri integration framework for specific Siri domains.

### Recommendation

Prefer App Intents for this app unless a specific SiriKit domain is needed.

---

## 13.5 UserNotifications

### Role in the project

Local notifications for meeting/post-processing status.

Use it for:

- “Meeting summary is ready.”
- “Transcription failed; tap to retry.”
- “You have 3 unresolved action items.”
- “Follow-up email draft is ready.”

### Recommendation

Useful after processing can happen asynchronously or after app state changes.

---

## 13.6 ShareLink, Transferable, and Share Sheet

### Role in the project

Native sharing/export.

Use it for:

- Sharing Markdown summary.
- Sharing transcript TXT.
- Sharing JSON export.
- Sending to Files, Mail, Notes, Messages, etc.

### Recommendation

Use in MVP 1 export flow.

---

## 14. UI, System Surfaces, and Experience

## 14.1 SwiftUI

### Role in the project

Primary UI framework.

Use it for:

- Chat UI.
- Meeting recording screen.
- Transcript view.
- Settings.
- Provider configuration.
- Export screens.
- Summary dashboard.

### Recommendation

Use SwiftUI from the beginning.

Design with separate view models/services. Avoid putting audio/transcription logic inside views.

---

## 14.2 UIKit

### Role in the project

Fallback for advanced UI or legacy components.

Use it only when SwiftUI is not enough.

Possible uses:

- Document picker edge cases.
- Advanced text editing.
- Custom share controllers.
- Audio waveform components.

### Recommendation

SwiftUI first. UIKit only where necessary.

---

## 14.3 WidgetKit

### Role in the project

Home screen / lock screen widgets.

Use it for:

- Show latest meeting status.
- Quick access to recent summaries.
- Show pending action items.
- Quick launch recording.

### Recommendation

Not MVP. Useful once meeting archive exists.

---

## 14.4 ActivityKit / Live Activities

### Role in the project

Show active meeting recording status on Lock Screen / Dynamic Island / StandBy where supported.

### iPhone 14 Plus note

iPhone 14 Plus does not have Dynamic Island, but Live Activities can still be useful on the Lock Screen depending on OS support.

### Use cases

- Recording timer.
- Transcription status.
- Processing status.
- Tap to return to active meeting.

### Recommendation

Add after recording is stable.

---

## 15. Search, Memory, and Retrieval

## 15.1 Local Full-Text Search

### Role in the project

Search across transcripts, summaries, tasks, and project notes.

Implementation options:

- SQLite FTS.
- Core Spotlight.
- Custom token index.
- Hybrid metadata + text file scanning for MVP.

### Recommendation

For project memory, do not jump immediately to embeddings.

Start with:

```text
Full-text search + metadata filters + segment references
```

Then add embeddings later.

---

## 15.2 Local Embeddings

### Role in the project

Semantic search across meetings.

Possible implementation options:

- Small Core ML embedding model.
- Remote embedding provider.
- Local network embedding server on Mac.
- Apple/system semantic indexing where available.

### Recommendation

For iPhone 14 Plus, start with remote or local-network embeddings if needed. Local Core ML embeddings are possible but should be tested for speed/storage/quality.

---

## 15.3 Core Spotlight Semantic Search

### Role in the project

Apple has been improving private on-device indexing and semantic search.

Potential use:

- Let system-level search find app content.
- Improve app-internal search experience.
- Surface project memory naturally.

### Recommendation

Research after basic archive exists.

---

## 16. Development, Testing, and Distribution Tools

## 16.1 Xcode

### Role in the project

Primary IDE and build environment.

Use it for:

- SwiftUI app development.
- iPhone deployment.
- Debugging audio permissions.
- Instruments profiling.
- Core ML model integration.
- Swift Package Manager dependencies.

### Recommendation

Start with a simple native iOS app target.

Avoid overcomplicating with backend or cross-platform framework at the beginning.

---

## 16.2 Swift Package Manager

### Role in the project

Dependency manager.

Use it for:

- WhisperKit.
- Networking helpers if needed.
- Markdown rendering/export libraries if needed.
- SQLite wrappers if SwiftData is not enough.

### Recommendation

Keep dependencies minimal at first.

---

## 16.3 Instruments

### Role in the project

Performance and energy profiling.

Use it for:

- Battery impact of recording.
- CPU usage during transcription.
- Memory pressure during WhisperKit.
- Thermal behavior.
- Background task behavior.

### Recommendation

Critical for local transcription testing.

Benchmark matrix:

```text
Engine: Apple Speech / SpeechAnalyzer / WhisperKit
Audio length: 1 min / 10 min / 60 min
Mode: foreground / locked screen / interrupted
Metrics: time, battery, heat, memory, transcript quality
```

---

## 16.4 TestFlight / Apple Developer Program

### Role in the project

Testing outside your own device and distribution to testers.

### Recommendation

Not needed for first personal testing on your iPhone. Needed later if other people will install/test through TestFlight.

---

## 17. What Is Possible vs. Not Possible on iPhone 14 Plus

## 17.1 Strongly Possible

- Native meeting recording.
- Local audio file storage.
- Apple speech-to-text.
- Remote AI chat through APIs.
- OpenAI-compatible local network provider.
- Secure API key storage.
- Local transcripts and summaries.
- Markdown/JSON export.
- Calendar/Reminders integration.
- Local NLP helpers.
- OCR with Vision.
- Core ML inference for small models.
- WhisperKit experiments.
- Core Spotlight indexing.

## 17.2 Possible but Needs Testing

- Long live transcription with Apple Speech/SpeechAnalyzer.
- WhisperKit real-time transcription on long meetings.
- Speaker diarization on-device.
- Local embeddings on-device.
- Background recording under real conditions.
- Battery impact of 60+ minute meetings.
- Bluetooth microphone quality and routing.
- Local network discovery of LM Studio/Ollama.

## 17.3 Not a Good Baseline for iPhone 14 Plus

- Apple Foundation Models as a required feature.
- Apple Intelligence-powered local LLM workflows.
- Large local LLM chat directly on-device.
- Heavy multi-agent local reasoning.
- Continuous local transcription + diarization + summarization all at once without careful profiling.

---

## 18. Proposed Technical Architecture Update

Add these services to the main architecture:

```text
Audio Layer
 ├── AudioSessionManager
 ├── AudioCaptureService
 ├── AudioFileWriter
 ├── AudioLevelMonitor
 └── AudioPlaybackNavigator

Transcription Layer
 ├── TranscriptionEngine protocol
 ├── AppleSpeechRecognizerEngine
 ├── AppleSpeechAnalyzerEngine
 ├── WhisperKitEngine
 └── RemoteTranscriptionEngine

Local Intelligence Layer
 ├── LocalNLPService
 ├── SoundAnalysisService
 ├── VisionOCRService
 ├── CoreMLModelRunner
 └── LocalEmbeddingService optional

Provider Layer
 ├── AIProvider protocol
 ├── OpenAICompatibleProvider
 ├── OpenAIProvider
 ├── GeminiProvider
 ├── AnthropicProvider
 ├── LocalNetworkProvider
 └── AppleFoundationModelProvider optional/unavailable on iPhone 14 Plus

Storage Layer
 ├── MeetingRepository
 ├── TranscriptRepository
 ├── FileArtifactStore
 ├── SecureKeyStore
 ├── SearchIndexStore
 └── OptionalCloudSyncStore

Ecosystem Layer
 ├── CalendarIntegrationService
 ├── ReminderIntegrationService
 ├── ContactsIntegrationService
 ├── AppIntentService
 ├── ShareExportService
 └── NotificationService
```

---

## 19. Recommended MVP Adjustment Based on Apple Ecosystem Research

## 19.1 MVP 1 Revised

Scope:

1. SwiftUI app.
2. AVAudioEngine-based recording.
3. Save `.m4a` audio locally.
4. Apple native transcription through a `TranscriptionEngine` abstraction.
5. OpenAI-compatible AI provider using URLSession.
6. Keychain storage for API key.
7. SwiftData metadata storage.
8. FileManager artifact storage.
9. Markdown export using ShareLink.
10. Manual provider setup.

## 19.2 MVP 1.5

Add:

1. Transcript segment model.
2. Local language detection with Natural Language.
3. Basic entity extraction with Natural Language.
4. Audio playback by transcript timestamp.
5. JSON export.
6. Manual meeting markers.

## 19.3 MVP 2

Add:

1. WhisperKit local transcription experiment.
2. SpeechAnalyzer engine if target iOS supports it.
3. Import audio files.
4. Re-transcribe meeting with another engine.
5. Local search.
6. EventKit calendar association.

## 19.4 MVP 3

Add:

1. Project memory.
2. Core Spotlight indexing.
3. Action items to Reminders.
4. OCR attachments with Vision.
5. App Intents / Shortcuts.
6. Optional encrypted meeting archives.

---

## 20. Recommended First Experiments on iPhone 14 Plus

## Experiment 1 — Native Recording Reliability

Goal:

- Record 5, 15, and 60 minute audio files.
- Test foreground and screen-lock behavior.
- Test interruptions.
- Test audio route changes.

Success criteria:

- No lost audio.
- File saved correctly.
- App recovers cleanly from interruption.

## Experiment 2 — Apple Transcription Quality

Goal:

- Transcribe short meeting-like audio.
- Test English, Portuguese, and mixed English/Portuguese if relevant.
- Test technical vocabulary.

Success criteria:

- Usable transcript.
- Partial results if live mode is enabled.
- Segment timestamps usable enough for navigation.

## Experiment 3 — WhisperKit Feasibility

Goal:

- Test tiny/base/small models.
- Compare speed and quality.
- Check battery and heat.

Success criteria:

- At least one model is practical for local offline transcription.
- Results are materially useful compared with Apple transcription.

## Experiment 4 — Local Network Provider

Goal:

- Connect iPhone to LM Studio running on Mac.
- Use OpenAI-compatible `/v1/chat/completions` style endpoint.
- Test streaming.

Success criteria:

- iPhone can talk to local model over Wi-Fi.
- Local network permission is handled cleanly.
- Provider abstraction works.

## Experiment 5 — Meeting Analysis Pipeline

Goal:

- Take transcript text.
- Generate JSON analysis.
- Extract decisions, action items, questions, risks, dates.

Success criteria:

- Structured JSON parses reliably.
- Each item links back to transcript segment IDs.
- Summary is useful enough to replace manual notes.

---

## 21. Opinionated Recommendation

For this project, the Apple ecosystem should be used in a very specific way:

```text
Use Apple frameworks for capture, storage, privacy, local helpers, search, and ecosystem integration.
Use external/local-network AI providers for heavy reasoning.
Use WhisperKit/Core ML for local speech-to-text experiments.
Do not depend on Apple Intelligence for the iPhone 14 Plus.
```

The strongest architecture is hybrid:

```text
Apple-native shell + provider-agnostic AI core + local-first data model
```

The first app should prove the workflow, not the AI ambition:

```text
Record reliably -> transcribe acceptably -> summarize usefully -> store cleanly -> export easily
```

Once that works, the project can grow into:

```text
project memory + offline transcription + local search + calendar/reminder integration + multi-provider AI workbench
```

---

## 22. Current Decision Register

| Decision | Current Recommendation |
|---|---|
| UI framework | SwiftUI |
| Audio capture | AVAudioEngine, not only AVAudioRecorder |
| Audio storage | FileManager/Application Support |
| Metadata storage | SwiftData initially |
| API key storage | Keychain Services |
| First transcription engine | Apple native Speech abstraction |
| Second transcription engine | WhisperKit |
| Heavy reasoning | Remote or local-network provider |
| Apple Foundation Models | Optional future provider, unavailable baseline on iPhone 14 Plus |
| Local NLP | Natural Language framework |
| Local OCR | Vision framework |
| Local sound features | Sound Analysis later |
| Calendar/reminders | EventKit later |
| Siri/Shortcuts | App Intents later |
| Search | Full-text first, embeddings later |
| Sync | Local first, CloudKit optional later |

---

## 23. Backlog Additions from Apple Ecosystem Research

Add these to the main product backlog:

- AppleSpeechAnalyzerEngine.
- WhisperKitEngine benchmark suite.
- AudioSessionManager.
- Audio interruption recovery tests.
- LocalNLPService.
- VisionOCRService for whiteboards/screenshots.
- SoundAnalysisService for silence/noise/event detection.
- LocalNetworkProvider discovery via Bonjour.
- Core Spotlight meeting indexing.
- EventKit meeting association.
- Reminders export for action items.
- App Intents for starting/stopping meeting recording.
- Live Activity for active recording timer.
- Optional Face ID lock for sensitive meetings.
- Optional encrypted meeting archive using CryptoKit.
- CloudKit sync mode options.

---

## 24. Key Takeaway

The iPhone 14 Plus is a good test device for building the real product foundation.

It is not the right baseline for Apple Intelligence-dependent local LLM features, but it is absolutely sufficient for:

- Native recording.
- Local files.
- Secure keys.
- Apple speech transcription.
- WhisperKit experiments.
- Local NLP helpers.
- OCR.
- Search.
- Provider-agnostic remote/local-network AI integration.

The project should therefore treat Apple Intelligence as a future enhancement, not as the center of the architecture.

