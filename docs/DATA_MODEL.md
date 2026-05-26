# Data Model — AI Meeting Companion iOS

## 1. Storage strategy

Use a hybrid local storage model:

```text
SwiftData:
  metadata, indexes, relationships

FileManager:
  large artifacts, audio, transcript JSON, export files

Keychain:
  secrets, API keys, encryption keys
```

## 2. Application Support folder structure

Recommended:

```text
Application Support/
  Meetings/
    {meetingId}/
      audio.m4a
      transcript.original.json
      transcript.edited.json
      analysis.latest.json
      provider.response.raw.txt
      exports/
        summary.md
        meeting.json
  Models/
    WhisperKit/
  Logs/
```

## 3. Core entities

## 3.1 Meeting

Purpose:

Represents a recorded or imported meeting.

Fields:

```swift
struct Meeting: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double?
    var projectId: UUID?
    var audioFileRelativePath: String?
    var transcriptionEngineId: String?
    var analysisProviderId: String?
    var languageCode: String?
    var tags: [String]
    var status: MeetingStatus
}
```

Possible status:

```swift
enum MeetingStatus: String, Codable {
    case draft
    case recording
    case recorded
    case transcribing
    case transcribed
    case analyzing
    case analyzed
    case failed
    case archived
}
```

## 3.2 TranscriptSegment

Purpose:

Stores a timestamped piece of transcript.

```swift
struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    let meetingId: UUID
    var startTime: Double
    var endTime: Double?
    var speakerId: UUID?
    var text: String
    var originalText: String?
    var confidence: Double?
    var languageCode: String?
    var sourceEngineId: String
}
```

Rules:

- Do not overwrite original text without preserving original.
- Keep timestamp if available.
- Speaker identity should be a separate layer.

## 3.3 Speaker

```swift
struct Speaker: Identifiable, Codable {
    let id: UUID
    let meetingId: UUID
    var label: String
    var displayName: String?
    var contactIdentifier: String?
}
```

## 3.4 MeetingAnalysis

```swift
struct MeetingAnalysis: Identifiable, Codable {
    let id: UUID
    let meetingId: UUID
    var createdAt: Date
    var providerId: String
    var model: String?
    var shortSummary: String
    var detailedSummary: String
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var risks: [Risk]
    var openQuestions: [OpenQuestion]
    var importantDates: [ImportantDate]
    var entities: [EntityMention]
    var topicTimeline: [TopicBlock]
    var rawProviderResponsePath: String?
}
```

## 3.5 ActionItem

```swift
struct ActionItem: Identifiable, Codable {
    let id: UUID
    var task: String
    var owner: String?
    var dueDate: Date?
    var status: ActionItemStatus
    var sourceSegmentIds: [UUID]
    var confidence: Double?
}
```

## 3.6 Decision

```swift
struct Decision: Identifiable, Codable {
    let id: UUID
    var title: String
    var details: String
    var sourceSegmentIds: [UUID]
    var confidence: Double?
}
```

## 3.7 Provider configuration

Provider metadata can live in SwiftData:

```swift
struct AIProviderConfig: Identifiable, Codable {
    let id: UUID
    var name: String
    var type: ProviderType
    var baseURL: URL?
    var defaultModel: String
    var supportsStreaming: Bool
    var supportsAudio: Bool
    var supportsTools: Bool
    var apiKeyKeychainIdentifier: String?
}
```

API key value must live in Keychain only.

## 3.8 Chat

```swift
struct ChatConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var providerId: UUID?
    var model: String?
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let conversationId: UUID
    var role: AIRole
    var content: String
    var createdAt: Date
}
```

## 4. Artifact versioning

For transcript and analysis:

- Keep original transcript.
- Save edited transcript separately.
- Save latest analysis.
- Preserve raw provider response when parsing fails.

## 5. Deletion behavior

When deleting a meeting, delete:

- SwiftData metadata.
- Transcript records.
- Analysis records.
- File artifacts under the meeting folder.

When deleting only raw audio:

- Remove `audio.m4a`.
- Keep transcript and analysis.
- Mark audio file path as nil.
