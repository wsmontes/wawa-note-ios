# Architecture — AI Meeting Companion iOS

## 1. Architectural principle

The app must be built as a native iOS application with clear boundaries between:

- UI
- domain logic
- audio capture
- transcription
- AI providers
- storage
- local intelligence helpers
- Apple ecosystem integrations

The architecture must avoid provider lock-in and must keep the recording/transcription/analysis pipeline modular.

Core architecture statement:

```text
Apple-native shell + provider-agnostic AI core + local-first data model
```

## 2. Target device constraint

The first physical test device is **iPhone 14 Plus**.

Architecture implications:

- Apple Intelligence / Foundation Models must not be a baseline dependency.
- Local LLM chat on-device is not MVP scope.
- WhisperKit is a later experiment, not MVP 1.
- Apple Speech / SpeechAnalyzer should sit behind a `TranscriptionEngine` abstraction.
- Remote or local-network AI providers should handle heavy reasoning.

## 3. Proposed module layout

Use the following structure once the Xcode project exists:

```text
AICompanion/
  App/
    AICompanionApp.swift
    AppRouter.swift

  UI/
    Meetings/
    Recording/
    Chat/
    Settings/
    Components/

  Domain/
    Models/
    Services/
    UseCases/

  Audio/
    AudioSessionManager.swift
    AudioCaptureService.swift
    AudioFileWriter.swift
    AudioLevelMonitor.swift
    AudioPlaybackService.swift

  Transcription/
    TranscriptionEngine.swift
    AppleSpeechTranscriptionEngine.swift
    SpeechAnalyzerTranscriptionEngine.swift
    RemoteTranscriptionEngine.swift
    WhisperKitTranscriptionEngine.swift

  Providers/
    AIProvider.swift
    ProviderRouter.swift
    OpenAICompatibleProvider.swift
    OpenAIProvider.swift
    GeminiProvider.swift
    AnthropicProvider.swift
    LocalNetworkProvider.swift
    AppleFoundationModelProvider.swift

  Storage/
    MeetingRepository.swift
    TranscriptRepository.swift
    FileArtifactStore.swift
    SecureKeyStore.swift
    ProviderConfigRepository.swift

  LocalIntelligence/
    LocalNLPService.swift
    SoundAnalysisService.swift
    VisionOCRService.swift
    CoreMLModelRunner.swift

  Ecosystem/
    ShareExportService.swift
    CalendarIntegrationService.swift
    ReminderIntegrationService.swift
    AppIntentService.swift
    NotificationService.swift

  Utilities/
    Errors.swift
    Logging.swift
    DateFormatting.swift
```

Only create modules when they are actually needed. Do not generate empty architecture just to match the folder tree.

## 4. Main layers

## 4.1 UI layer

Responsibilities:

- SwiftUI views.
- View models.
- User interaction.
- Navigation.
- Displaying recording, transcript, summary, settings.

Non-responsibilities:

- Direct audio engine handling.
- Direct provider HTTP calls.
- Direct Keychain calls.
- Direct file writing, except through services.

Rule:

```text
Views call view models.
View models call use cases/services.
Services call providers/storage/system APIs.
```

## 4.2 Domain layer

Responsibilities:

- Domain models.
- Use cases.
- Business workflows.
- Provider-independent data structures.

Core use cases:

- `StartMeetingRecordingUseCase`
- `StopMeetingRecordingUseCase`
- `TranscribeMeetingUseCase`
- `AnalyzeMeetingUseCase`
- `ExportMeetingUseCase`
- `SendChatMessageUseCase`

## 4.3 Audio layer

Responsibilities:

- Configure `AVAudioSession`.
- Capture audio.
- Save audio files.
- Monitor audio levels.
- Handle audio interruptions.
- Provide playback.

MVP recommendation:

Use `AVAudioEngine` if live buffers are needed. Use `AVAudioRecorder` only for a quick prototype, but keep it hidden behind `AudioCaptureService`.

## 4.4 Transcription layer

Responsibilities:

- Convert audio into timestamped transcript segments.
- Provide live or file-based transcription.
- Hide engine-specific details.

Required abstraction:

```swift
protocol TranscriptionEngine {
    var id: String { get }
    var displayName: String { get }

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript
    func startLiveTranscription() async throws -> AsyncThrowingStream<TranscriptSegment, Error>
    func stopLiveTranscription() async throws
}
```

MVP implementation:

```text
AppleSpeechTranscriptionEngine
```

Later implementations:

```text
SpeechAnalyzerTranscriptionEngine
WhisperKitTranscriptionEngine
RemoteTranscriptionEngine
```

## 4.5 Provider layer

Responsibilities:

- Normalize AI provider requests and responses.
- Hide OpenAI/Anthropic/Gemini/local-server differences.
- Support streaming.
- Support future structured output.

Required abstraction:

```swift
protocol AIProvider {
    var id: String { get }
    var displayName: String { get }
    var capabilities: AIProviderCapabilities { get }

    func send(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) async throws -> AsyncThrowingStream<AIChunk, Error>
}
```

MVP implementation:

```text
OpenAICompatibleProvider
```

## 4.6 Storage layer

Responsibilities:

- SwiftData metadata.
- File artifact storage.
- Secure key storage.
- Transcript and analysis persistence.

Recommended split:

```text
SwiftData:
  Meeting metadata
  Provider config metadata
  Project metadata
  Transcript segment indexes
  Analysis indexes

FileManager:
  audio.m4a
  transcript.original.json
  transcript.edited.json
  analysis.latest.json
  export markdown/json

Keychain:
  API keys
  provider tokens
  encryption keys
```

## 5. Meeting processing pipeline

MVP pipeline:

```text
User taps Record
  -> AudioCaptureService starts session
  -> AudioFileWriter writes audio
  -> User taps Stop
  -> Meeting record saved
  -> TranscriptionEngine transcribes audio
  -> Transcript segments saved
  -> AnalysisService sends transcript to AIProvider
  -> MeetingAnalysis saved
  -> UI shows summary and export options
```

## 6. Data boundary rule

Never pass provider-native JSON through the whole app.

Provider-specific JSON must be converted into internal models at the boundary.

Good:

```text
OpenAI JSON -> OpenAICompatibleProvider -> AIResponse -> app
```

Bad:

```text
OpenAI JSON -> ViewModel -> View -> Storage
```

## 7. Error handling

Use typed errors by layer:

```swift
enum AudioCaptureError: Error { ... }
enum TranscriptionError: Error { ... }
enum ProviderError: Error { ... }
enum StorageError: Error { ... }
enum SecurityError: Error { ... }
```

User-facing error text should be generated near the UI, not buried in low-level services.

## 8. Threading and concurrency

- Services should be async where appropriate.
- UI state updates must happen on the main actor.
- Long-running transcription/analysis must not block the UI.
- The app must save partial state before running expensive operations.

## 9. What not to build yet

Do not build in MVP 1:

- WhisperKit.
- Speaker diarization.
- Calendar integration.
- Reminders integration.
- CloudKit sync.
- Apple Foundation Models.
- Widgets.
- Live Activities.
- Complex local embeddings.
- Backend server.

These are later phases.
