# API Provider and Transcription Contracts

## 1. Purpose

This document defines the boundaries Claude Code should preserve when implementing providers and transcription engines.

Provider-specific APIs should be isolated behind internal contracts.

## 2. AIProvider contract

Initial version:

```swift
protocol AIProvider {
    var id: String { get }
    var displayName: String { get }
    var capabilities: AIProviderCapabilities { get }

    func send(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) async throws -> AsyncThrowingStream<AIChunk, Error>
}
```

## 3. AIProviderCapabilities

```swift
struct AIProviderCapabilities: Codable, Equatable {
    var supportsStreaming: Bool
    var supportsAudioInput: Bool
    var supportsStructuredOutput: Bool
    var supportsToolCalling: Bool
    var supportsEmbeddings: Bool
}
```

## 4. AIRequest

```swift
struct AIRequest: Codable {
    var model: String
    var messages: [AIMessage]
    var temperature: Double?
    var maxTokens: Int?
    var responseFormat: AIResponseFormat?
}
```

## 5. AIMessage

```swift
struct AIMessage: Codable, Identifiable {
    let id: UUID
    var role: AIRole
    var content: [AIContentBlock]
}
```

```swift
enum AIRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}
```

```swift
enum AIContentBlock: Codable {
    case text(String)
    case audioFile(URL)
    case imageFile(URL)
}
```

For MVP, only `.text` is required.

## 6. AIResponse

```swift
struct AIResponse: Codable {
    var id: String?
    var model: String?
    var content: String
    var rawResponsePath: String?
    var usage: AIUsage?
}
```

## 7. OpenAICompatibleProvider

MVP provider.

Responsibilities:

- Build OpenAI-compatible JSON request.
- Inject API key from Keychain.
- Send request using URLSession.
- Parse response.
- Return internal `AIResponse`.

Do not expose OpenAI-compatible JSON outside the provider.

Required config:

```text
baseURL
model
apiKeyKeychainIdentifier
```

Example base URLs:

```text
https://api.openai.com/v1
http://localhost:1234/v1
http://192.168.x.x:1234/v1
```

For iPhone to Mac local server, `localhost` means the iPhone itself, not the Mac. Use Mac LAN IP or Bonjour discovery later.

## 8. TranscriptionEngine contract

Initial version:

```swift
protocol TranscriptionEngine {
    var id: String { get }
    var displayName: String { get }

    func transcribeFile(_ audioFileURL: URL) async throws -> Transcript
}
```

Later live version:

```swift
protocol LiveTranscriptionEngine: TranscriptionEngine {
    func startLiveTranscription() async throws -> AsyncThrowingStream<TranscriptSegment, Error>
    func stopLiveTranscription() async throws
}
```

## 9. Transcript

```swift
struct Transcript: Codable {
    var meetingId: UUID?
    var languageCode: String?
    var segments: [TranscriptSegment]
    var sourceEngineId: String
    var createdAt: Date
}
```

## 10. MVP transcription engines

Implement in this order:

1. `AppleSpeechTranscriptionEngine`
2. `SpeechAnalyzerTranscriptionEngine` if available and target supports it
3. `WhisperKitTranscriptionEngine`
4. `RemoteTranscriptionEngine`

## 11. Provider routing

`ProviderRouter` should select the current provider based on config.

It should not know provider-specific JSON.

```swift
final class ProviderRouter {
    func provider(for config: AIProviderConfig) throws -> AIProvider
}
```

## 12. AnalysisService

The `AnalysisService` should not call OpenAI/Gemini directly.

Good:

```text
AnalysisService -> AIProvider -> OpenAICompatibleProvider -> URLSession
```

Bad:

```text
AnalysisService -> URLSession -> OpenAI JSON
```

## 13. Streaming

Streaming is not required for meeting summary MVP.

Add streaming first to chat, not to meeting analysis.
