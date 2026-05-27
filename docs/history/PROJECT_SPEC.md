# AI Meeting Companion / Universal AI Client for iPhone — Specification

## 1. Product Vision

Build an iOS application that works as a universal AI assistant and meeting companion.

The app should run on iPhone and support both:

- Local AI capabilities running on-device or on the local network.
- Remote AI providers accessed through APIs.

The application should behave like a flexible ChatGPT-style client, but without being locked to a single provider. It should also be able to listen to meetings, transcribe speech, summarize discussions, extract useful information, and allow the user to interact with the meeting content afterward.

Core product idea:

> A local-first, provider-agnostic AI client for iPhone, capable of chat, meeting recording, transcription, summarization, structured analysis, and future project memory.

---

## 2. Product Goals

### 2.1 Main Goals

1. Provide a chat interface similar to ChatGPT.
2. Allow the user to select different AI providers and models.
3. Record meetings from the iPhone.
4. Transcribe meetings using either local or remote transcription engines.
5. Summarize meetings automatically.
6. Extract decisions, action items, risks, questions, topics, dates, and entities.
7. Allow the user to ask questions about a meeting after it is recorded.
8. Store meetings, transcripts, summaries, and analyses locally.
9. Support a privacy-aware workflow where the user controls what leaves the device.
10. Evolve into a reusable personal AI workbench for meetings, projects, and notes.

### 2.2 Design Principles

- Provider-agnostic by design.
- Local-first when practical.
- Clear separation between audio, transcription, analysis, and chat.
- Keep original data intact.
- Store structured outputs, not only plain text.
- Make every AI-generated claim traceable back to transcript segments.
- Start simple, but design the architecture so it can grow.

---

## 3. Target Platforms

### 3.1 Initial Platform

- iPhone.
- Native iOS app built with Xcode.
- Swift and SwiftUI preferred.

### 3.2 Future Platforms

Possible later expansions:

- iPad.
- macOS companion app.
- Apple Watch quick recorder.
- Web dashboard.
- Shared local project database.

---

## 4. Main Use Cases

### 4.1 General Chat

The user opens the app and starts a conversation with an AI model.

The app should support:

- Text input.
- Voice input.
- Streaming responses.
- Model selection.
- Provider selection.
- Chat history.
- Saved conversations.

### 4.2 Meeting Recording

The user starts a meeting session.

The app should:

1. Capture audio from the microphone.
2. Save the audio locally.
3. Transcribe the conversation live or after recording.
4. Segment the transcript by time.
5. Optionally detect speakers.
6. Generate a meeting summary.
7. Extract structured meeting intelligence.
8. Save everything as a meeting record.

### 4.3 Import Existing Audio

The user imports an existing audio file.

The app should:

1. Accept common audio formats.
2. Transcribe the file.
3. Generate structured analysis.
4. Save the result as a meeting.

### 4.4 Ask Questions About a Meeting

After a meeting is processed, the user can ask questions such as:

- What decisions were made?
- What tasks were assigned?
- Who is responsible for each item?
- What dates were mentioned?
- What risks or blockers appeared?
- What parts were unclear?
- Generate a follow-up email.
- Generate Jira stories.
- Generate a formal meeting note.

### 4.5 Project-Based Meeting Memory

The user can group meetings by project.

Example:

- Project: GLPR
- Project: DataWalk Brazil
- Project: Personal AI App

The app should eventually answer questions across multiple meetings within the same project.

---

## 5. Functional Requirements

## 5.1 Chat Requirements

### FR-001 — Universal Chat Interface

The app must provide a chat interface where the user can send messages and receive responses from a selected AI model.

### FR-002 — Multiple AI Providers

The app must support multiple AI providers through a common internal interface.

Possible providers:

- OpenAI.
- Anthropic.
- Google Gemini.
- Mistral.
- OpenAI-compatible APIs.
- LM Studio running on the local network.
- Ollama or similar local model servers.
- Apple local models where available.

### FR-003 — Provider Configuration

The user must be able to configure providers manually.

Provider configuration fields:

- Provider name.
- Provider type.
- Base URL.
- API key.
- Default model.
- Streaming support.
- Audio support.
- Tool/function-calling support.
- Notes.

### FR-004 — Secure API Key Storage

API keys must be stored securely using the iOS Keychain.

### FR-005 — OpenAI-Compatible Provider Mode

The app must support generic OpenAI-compatible APIs.

This is important for providers and local servers that expose endpoints similar to OpenAI's API.

Example configuration:

```text
Provider Type: OpenAI-compatible
Base URL: http://192.168.0.10:1234/v1
Model: local-model
API Key: optional
```

---

## 5.2 Meeting Recording Requirements

### FR-006 — Start Meeting Recording

The user must be able to start a meeting recording from the app.

### FR-007 — Pause and Resume Recording

The user must be able to pause and resume recording.

### FR-008 — Stop Recording

The user must be able to stop the recording and trigger post-processing.

### FR-009 — Save Raw Audio

The app must save the raw audio file locally unless the user chooses not to keep it.

### FR-010 — Delete Raw Audio

The user must be able to delete the raw audio while keeping transcript and analysis.

### FR-011 — Meeting Metadata

Each meeting should store:

- Meeting ID.
- Title.
- Created date.
- Duration.
- Audio file path.
- Transcription engine used.
- AI provider used for analysis.
- Language.
- Project association.
- Tags.

---

## 5.3 Transcription Requirements

### FR-012 — Transcription Engine Abstraction

The app must define a common abstraction for transcription engines.

Conceptual interface:

```swift
protocol TranscriptionEngine {
    func startLiveTranscription() async throws
    func stopLiveTranscription() async throws -> Transcript
    func transcribeFile(_ audioFile: URL) async throws -> Transcript
}
```

### FR-013 — Apple Native Transcription

The app should support Apple's native speech recognition capabilities as an initial transcription engine.

### FR-014 — Whisper Local Transcription

The app should support local Whisper-based transcription in a later phase, likely using a Swift/Core ML-compatible implementation.

### FR-015 — Remote Transcription APIs

The app should support remote transcription providers, such as OpenAI or Gemini, depending on provider capabilities.

### FR-016 — Transcript Segmentation

The transcript must be stored in timestamped segments.

Example:

```json
{
  "segmentId": "uuid",
  "start": 125.2,
  "end": 139.8,
  "speaker": "Speaker 1",
  "text": "We need to confirm the deployment date before Friday.",
  "confidence": 0.91,
  "language": "en"
}
```

### FR-017 — Transcript Editing

The user must be able to edit transcript text manually.

The original transcript should be preserved or recoverable.

### FR-018 — Reprocess Transcript

The user should be able to re-run analysis on an edited transcript without re-recording audio.

### FR-019 — Reprocess Audio

The user should be able to re-transcribe audio using a different transcription engine.

---

## 5.4 Speaker Requirements

### FR-020 — Basic Speaker Labels

The app should support basic speaker labels such as:

- Speaker 1
- Speaker 2
- Speaker 3

### FR-021 — Manual Speaker Rename

The user must be able to rename speakers manually.

Example:

- Speaker 1 → Wagner
- Speaker 2 → Robert

### FR-022 — Speaker Layer Separation

Speaker information should be stored as a separate layer from transcript text.

This avoids corrupting transcript content when speaker identification changes.

---

## 5.5 Meeting Analysis Requirements

### FR-023 — Short Summary

The app must generate a short summary of the meeting.

### FR-024 — Detailed Summary

The app must generate a more detailed summary.

### FR-025 — Decisions

The app must extract decisions made during the meeting.

Each decision should include evidence from transcript segments where possible.

### FR-026 — Action Items

The app must extract action items.

Each action item should include:

- Task.
- Owner, if known.
- Due date, if known.
- Status.
- Source transcript segment IDs.
- Confidence level.

Example:

```json
{
  "task": "Confirm deployment date",
  "owner": "Robert",
  "dueDate": "2026-05-29",
  "sourceSegmentIds": ["seg-123", "seg-124"],
  "confidence": 0.84
}
```

### FR-027 — Open Questions

The app must identify unresolved questions.

### FR-028 — Risks and Blockers

The app must identify risks, blockers, dependencies, and concerns.

### FR-029 — Important Dates

The app must extract dates mentioned during the meeting.

### FR-030 — People and Entities

The app should extract people, systems, organizations, tools, and projects mentioned during the meeting.

### FR-031 — Topic Timeline

The app should split the meeting into topic blocks.

Example:

```json
[
  {
    "topic": "Deployment planning",
    "start": 0,
    "end": 820
  },
  {
    "topic": "API integration issues",
    "start": 821,
    "end": 1540
  }
]
```

### FR-032 — Follow-Up Email Draft

The app should be able to generate a follow-up email based on the meeting.

### FR-033 — Meeting Note Formats

The app should generate different styles of meeting notes:

- Informal summary.
- Formal minutes.
- Technical summary.
- Executive summary.
- Action-item-focused summary.

---

## 5.6 Manual Meeting Markers

### FR-034 — Mark Important Moment

During recording, the user should be able to mark a moment as important.

### FR-035 — Marker Types

Possible marker types:

- Important.
- Decision.
- Follow-up.
- Question.
- Risk.
- Confusing.
- Revisit later.

### FR-036 — Markers Linked to Timestamp

Each marker must be linked to an audio timestamp and nearby transcript segment.

---

## 5.7 Glossary Requirements

### FR-037 — Custom Glossaries

The app should allow the user to create custom glossaries.

Example:

```json
{
  "name": "ICBC / GLPR",
  "terms": [
    "GLPR",
    "DR-API",
    "DLBT",
    "DSCS",
    "Globalscape",
    "Engage One",
    "COR segment"
  ]
}
```

### FR-038 — Glossary Use in Transcription

Glossaries should help transcription and post-transcription correction.

### FR-039 — Glossary Use in Analysis

Glossaries should help the AI correctly understand domain-specific terms.

---

## 5.8 Import and Export Requirements

### FR-040 — Import Audio Files

The app should support importing common audio formats:

- m4a.
- mp3.
- wav.
- aac.

### FR-041 — Export Markdown

The app must export meeting summaries and transcripts as Markdown.

### FR-042 — Export JSON

The app should export structured meeting data as JSON.

### FR-043 — Export Plain Text

The app should export transcript and summary as plain text.

### FR-044 — Future PDF Export

The app may export formal meeting notes as PDF in a later phase.

### FR-045 — Share Sheet Integration

The app should support iOS Share Sheet for exporting or sharing meeting results.

---

## 6. Non-Functional Requirements

## 6.1 Privacy

### NFR-001 — User Control Over Data Flow

The user must be able to control what is processed locally and what is sent to APIs.

Modes:

| Mode | Description |
|---|---|
| Fully local | Audio, transcription, and analysis stay on device when supported. |
| Local transcription + remote analysis | Audio stays local; transcript is sent to API. |
| Remote transcription + remote analysis | Audio and transcript may be sent to provider. |
| Manual | User chooses engine per step. |

### NFR-002 — Clear Processing Status

The UI must clearly indicate whether the current operation is local or remote.

### NFR-003 — API Keys Stay Local

API keys must remain on the user's device.

---

## 6.2 Reliability

### NFR-004 — Long Meeting Support

The app should support long recordings without losing data.

### NFR-005 — Incremental Saving

The app should save meeting state incrementally during recording and processing.

### NFR-006 — Recover From Failure

If transcription or analysis fails, the original audio and partial transcript should remain available.

---

## 6.3 Performance

### NFR-007 — Responsive Recording UI

The recording screen should stay responsive during audio capture.

### NFR-008 — Background Constraints

The app must account for iOS background execution limitations.

### NFR-009 — Chunked Processing

Long audio and long transcripts should be processed in chunks.

---

## 6.4 Maintainability

### NFR-010 — Modular Architecture

The app should be structured around replaceable modules:

- AI providers.
- Transcription engines.
- Audio recorder.
- Analysis services.
- Storage repositories.
- Exporters.

### NFR-011 — Avoid Provider Lock-In

Provider-specific logic should remain isolated.

### NFR-012 — Structured Internal Models

The app should use internal data models instead of passing raw provider JSON throughout the application.

---

## 7. Architecture

## 7.1 Proposed High-Level Architecture

```text
iOS App
 ├── UI Layer
 │    ├── ChatView
 │    ├── MeetingRecorderView
 │    ├── TranscriptView
 │    ├── MeetingSummaryView
 │    └── SettingsView
 │
 ├── Domain Layer
 │    ├── MeetingService
 │    ├── ChatService
 │    ├── TranscriptionService
 │    ├── AnalysisService
 │    └── ProviderRouter
 │
 ├── Provider Layer
 │    ├── OpenAIProvider
 │    ├── AnthropicProvider
 │    ├── GeminiProvider
 │    ├── AppleLocalProvider
 │    ├── OpenAICompatibleProvider
 │    └── LocalNetworkProvider
 │
 ├── Audio Layer
 │    ├── AudioRecorder
 │    ├── AudioChunker
 │    ├── AudioNormalizer
 │    └── AudioPlaybackService
 │
 ├── Storage Layer
 │    ├── MeetingRepository
 │    ├── TranscriptRepository
 │    ├── ChatRepository
 │    ├── ProviderConfigRepository
 │    └── SecureKeyStore
 │
 └── Model Layer
      ├── Meeting
      ├── TranscriptSegment
      ├── Speaker
      ├── AIMessage
      ├── AIProviderConfig
      └── MeetingAnalysis
```

---

## 8. Suggested Internal Models

## 8.1 Meeting

```swift
struct Meeting {
    let id: UUID
    var title: String
    var createdAt: Date
    var durationSeconds: Double
    var projectId: UUID?
    var audioFileURL: URL?
    var transcriptionEngineId: String?
    var analysisProviderId: String?
    var tags: [String]
}
```

## 8.2 TranscriptSegment

```swift
struct TranscriptSegment {
    let id: UUID
    let meetingId: UUID
    var startTime: Double
    var endTime: Double
    var speakerId: UUID?
    var text: String
    var confidence: Double?
    var language: String?
}
```

## 8.3 MeetingAnalysis

```swift
struct MeetingAnalysis {
    let meetingId: UUID
    var shortSummary: String
    var detailedSummary: String
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var risks: [Risk]
    var openQuestions: [OpenQuestion]
    var importantDates: [ImportantDate]
    var entities: [EntityMention]
    var topicTimeline: [TopicBlock]
}
```

## 8.4 AIProviderConfig

```swift
struct AIProviderConfig {
    let id: UUID
    var name: String
    var type: ProviderType
    var baseURL: URL?
    var defaultModel: String
    var supportsStreaming: Bool
    var supportsAudio: Bool
    var supportsTools: Bool
}
```

---

## 9. Prompt Templates

## 9.1 Meeting Summarizer

```text
You are analyzing a meeting transcript.

Return structured JSON with:
- short_summary
- detailed_summary
- decisions
- action_items
- open_questions
- risks
- important_dates
- mentioned_people
- mentioned_systems
- follow_up_email_draft

Do not invent information. If something is unclear, mark it as uncertain.
Every extracted item should include evidence from transcript segment IDs when available.
```

## 9.2 Action Item Extractor

```text
Extract only concrete action items from the meeting transcript.

Each item must include:
- task
- owner, if known
- due date, if known
- evidence from transcript
- confidence level

Do not include vague intentions unless they clearly imply work to be done.
```

## 9.3 Topic Segmenter

```text
Split the transcript into coherent topic blocks.

Each block must have:
- title
- start timestamp
- end timestamp
- short explanation
- related transcript segment IDs
```

---

## 10. MVP Plan

## MVP 1 — Basic Meeting Recorder and Analyzer

Scope:

1. SwiftUI app.
2. Record audio.
3. Save audio locally.
4. Transcribe using Apple native speech recognition.
5. Send transcript to one OpenAI-compatible provider.
6. Generate meeting summary.
7. Save meeting locally.
8. Export Markdown.

MVP 1 should prove the core loop:

> record → transcribe → analyze → save → review

## MVP 2 — Provider Abstraction

Add:

1. OpenAI provider.
2. OpenAI-compatible provider.
3. Gemini provider.
4. API key management.
5. Streaming chat.
6. Provider/model selection per conversation.

## MVP 3 — Whisper Local Transcription

Add:

1. Whisper-based local transcription.
2. Transcription engine selection.
3. Audio import.
4. Re-transcription.
5. Glossary support.

## MVP 4 — Meeting Intelligence

Add:

1. Decisions.
2. Action items.
3. Risks.
4. Open questions.
5. Topic timeline.
6. Chat with meeting.
7. Manual markers.

## MVP 5 — Local-First Intelligence

Add:

1. Apple local model support where available.
2. Local lightweight classification.
3. Offline mode.
4. Project-based meeting memory.

---

## 11. Open Decisions

The following decisions are still open and should be refined later:

1. Minimum iOS version.
2. Whether to use SwiftData, SQLite, or another persistence layer.
3. Whether local Whisper should be included in MVP 1 or delayed.
4. Whether to support live transcription from the beginning.
5. Whether analysis should happen automatically after recording or manually.
6. Whether project memory should use embeddings, full-text search, or both.
7. Whether the app should have a backend in the future.
8. Whether provider configurations should be importable/exportable.
9. Whether the app should support calendar integration.
10. Whether meeting audio should be encrypted at rest.

---

## 12. Backlog Ideas

- Calendar integration.
- Contact integration.
- Apple Reminders integration.
- Jira export.
- Confluence export.
- Obsidian export.
- Meeting comparison across dates.
- Project-level memory.
- Automatic glossary suggestions.
- Voice command mode.
- Real-time assistant during meetings.
- Smart notification after meeting ends.
- Multi-language meeting support.
- Speaker voice profiles.
- On-device embeddings.
- Local search across all meetings.
- Shared encrypted sync.
- Mac companion app.

---

## 13. Current Working Assumption

The first practical implementation should not try to solve all local AI features immediately.

Recommended first build:

```text
SwiftUI + local audio recording + Apple native transcription + OpenAI-compatible analysis provider + local storage + Markdown export
```

Then evolve toward:

```text
Whisper local transcription + multiple AI providers + meeting Q&A + project memory + local-first analysis
```

The key architectural requirement from day one is to keep providers and transcription engines abstracted behind protocols so they can be replaced or expanded without rewriting the app.

