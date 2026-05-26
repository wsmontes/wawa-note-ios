# Coding Standards — AI Meeting Companion iOS

## 1. General style

- Write simple Swift first.
- Keep files focused.
- Prefer strong types over dictionaries.
- Prefer small protocols at system boundaries.
- Use dependency injection through initializers.
- Do not create a giant service container unless the codebase requires it.
- Avoid speculative abstractions beyond the planned modules.
- Avoid empty placeholder modules unless needed by current work.

## 2. SwiftUI

Rules:

- Views should be declarative and thin.
- Business logic belongs in view models or services.
- Views should not directly use `URLSession`, `AVAudioEngine`, `Keychain`, or provider SDKs.
- Use `@MainActor` for UI-facing state.
- Avoid large view files. Split reusable UI into components.

Recommended pattern:

```swift
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var state: RecordingState = .idle

    private let recorder: AudioCaptureService

    init(recorder: AudioCaptureService) {
        self.recorder = recorder
    }
}
```

## 3. Swift Concurrency

Use `async/await` for:

- Provider calls.
- Transcription.
- File operations that may take time.
- Analysis operations.
- Export generation.

Do not block the main thread.

## 4. Error handling

Prefer typed error enums:

```swift
enum ProviderError: Error {
    case missingAPIKey
    case invalidResponse
    case requestFailed(statusCode: Int)
    case decodingFailed
}
```

Low-level services should return errors. UI/view models translate errors into user-facing messages.

## 5. Provider integration

Rules:

- Provider-specific request/response JSON must stay inside provider implementation.
- App code should use internal models only.
- Start with `OpenAICompatibleProvider`.
- Add official OpenAI/Gemini/Anthropic providers later if needed.
- Do not log API keys or raw authorization headers.

## 6. Audio

Rules:

- Centralize audio session configuration in `AudioSessionManager`.
- Do not configure `AVAudioSession` in multiple views.
- Keep recording state explicit.
- Save audio before running analysis.
- Do not assume transcription/analysis can run indefinitely in the background.

## 7. Transcription

Rules:

- All transcription engines must conform to `TranscriptionEngine`.
- Native Apple transcription is MVP.
- WhisperKit is not MVP unless explicitly requested.
- Keep transcript segments timestamped when possible.
- Preserve original transcript before manual edits.

## 8. Storage

Recommended split:

- SwiftData: metadata and indexable objects.
- FileManager: audio and large JSON artifacts.
- Keychain: API keys and secrets.

Do not store:

- API keys in SwiftData.
- API keys in UserDefaults.
- API keys in plain JSON.
- Large audio blobs in SwiftData.

## 9. Documentation update rule

Whenever implementing or changing architecture:

- Update `docs/TASKS.md`.
- Update `docs/DECISIONS.md` if a design decision changes.
- Update relevant docs when behavior changes.

## 10. Testing expectation

For each implemented service, add at least one of:

- Unit test.
- Preview/test harness.
- Manual test instructions in `docs/TEST_PLAN.md`.

Do not claim something works on iPhone 14 Plus until tested on device.
