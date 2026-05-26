# UX/UI Manual — AI Meeting Companion / Universal AI Client for iPhone

Companion document for:

- `docs/PROJECT_SPEC.md`
- `docs/APPLE_TECH_INVENTORY.md`
- `docs/ARCHITECTURE.md`
- `docs/IMPLEMENTATION_PLAN.md`

Target device for first real testing: **iPhone 14 Plus**

Design target: **native iOS app using SwiftUI, Apple-native patterns, and a calm professional product experience**

---

## 1. Purpose of This Manual

This document defines the UX and UI direction for the AI Meeting Companion / Universal AI Client.

It should guide product design, SwiftUI implementation, Claude Code tasks, component decisions, copywriting, layout, navigation, accessibility, and future design reviews.

The goal is not to create a visually loud AI app. The goal is to create an app that feels like it belongs on iPhone:

- clear,
- calm,
- fast,
- trustworthy,
- respectful of privacy,
- useful during real meetings,
- easy to understand under pressure,
- consistent with Apple platform quality.

The app should feel closer to a polished Apple productivity tool than to a generic chatbot demo.

---

## 2. Product UX North Star

The UX north star is:

> Help the user capture a meeting, understand it, and reuse its knowledge with as little friction as possible.

The product must make three things extremely clear at all times:

1. **What is happening now?**
   - Recording?
   - Transcribing?
   - Analyzing?
   - Waiting for API?
   - Saved?

2. **Where is the data going?**
   - Local only?
   - Local transcription + remote analysis?
   - Remote transcription?
   - Local network provider?

3. **What can the user do next?**
   - Continue recording.
   - Pause.
   - Mark important moment.
   - Review transcript.
   - Generate summary.
   - Ask about the meeting.
   - Export.

If the app answers these three questions, it will already feel better than most AI productivity tools.

---

## 3. Core UX Principles

## 3.1 Use Apple-Native Patterns First

Default to Apple system patterns before inventing custom UI.

Use:

- `NavigationStack`
- `TabView`
- `List`
- `Form`
- `Sheet`
- `ConfirmationDialog`
- `ToolbarItem`
- `ShareLink`
- native controls
- native gestures
- SF Symbols
- system colors
- Dynamic Type

Avoid:

- custom navigation systems,
- web-app-style sidebars on iPhone,
- dense dashboards,
- floating mystery buttons,
- excessive gradients,
- custom glass effects that fight the OS,
- custom controls that do not behave like iOS controls.

The app should look intentional, but it should not look like it is fighting UIKit/SwiftUI.

---

## 3.2 One Primary Action Per Screen

Every screen should have one obvious primary action.

Examples:

| Screen | Primary action |
|---|---|
| Home | Start Meeting |
| Active Recording | Stop Recording |
| Meeting Processing | Review Summary when ready |
| Meeting Detail | Ask about this meeting |
| Chat | Send message |
| Provider Settings | Save provider |
| Import Audio | Choose file |

Secondary actions can exist, but should be visually quieter.

Bad pattern:

```text
Start Recording / Import / Analyze / Ask / Export / Settings all competing equally.
```

Good pattern:

```text
Big primary action + small secondary alternatives.
```

---

## 3.3 Preserve the User's Work

A meeting recording is high-value data. Losing it would destroy trust.

UX rule:

> Recording safety is more important than AI cleverness.

Therefore:

- Save audio incrementally where possible.
- Never depend on AI analysis to preserve the recording.
- If transcription fails, keep audio.
- If analysis fails, keep transcript.
- If export fails, keep the meeting.
- If provider call fails, offer retry.
- Never auto-delete audio without explicit user action.

The UI should communicate recovery clearly:

```text
Recording saved. Transcription failed. You can retry.
```

Not:

```text
Something went wrong.
```

---

## 3.4 Make AI Traceable

AI output should be useful, but not mystical.

For every important extracted item, the UI should eventually allow the user to see where it came from.

Examples:

- Decision → source transcript segment.
- Action item → source timestamp.
- Risk → related quote/segment.
- Date → original mention.
- Entity → transcript context.

MVP can start simple with timestamp chips:

```text
Decision: Deploy after QA signoff.  12:45
```

Later:

```text
Decision: Deploy after QA signoff.
Evidence: Speaker 2 at 12:45 — “Let's wait until QA signs off.”
```

UX rule:

> AI summaries should be skimmable. AI claims should be inspectable.

---

## 3.5 Progressive Disclosure

Do not show all technical complexity immediately.

The app supports providers, privacy modes, transcription engines, local network APIs, and future local models. That does not mean the first screen should expose all of it.

Use progressive disclosure:

- Home shows simple status.
- Recording screen shows active engine and privacy mode.
- Settings lets advanced users configure details.
- Advanced options stay behind disclosure groups or detail screens.

Example:

Simple view:

```text
Transcription: Apple Speech
Analysis: Local network provider
```

Advanced view:

```text
Provider type: OpenAI-compatible
Base URL: http://192.168.1.25:1234/v1
Model: qwen2.5-coder
Streaming: enabled
```

---

## 3.6 Calm by Default, Urgent Only When Needed

The app records meetings. The user may be in a live conversation, distracted, or under pressure.

UI should be calm:

- muted system backgrounds,
- readable text,
- clear status,
- restrained animation,
- no gamification,
- no exaggerated AI personality,
- no constant notifications.

Use urgency only for:

- recording active,
- recording failed,
- permission missing,
- data loss risk,
- destructive actions.

---

## 3.7 Local/Remote Transparency

Because privacy is a core product value, local/remote status must be visible.

Use concise badges:

- `Local`
- `Remote`
- `Local Network`
- `Hybrid`
- `Audio stays on device`
- `Transcript sent to provider`

Do not bury this only in settings.

A user should be able to answer:

> Did my audio leave the phone?

from the meeting detail screen.

---

## 4. UX Personality

## 4.1 Product Character

The product should feel:

- intelligent,
- quiet,
- precise,
- professional,
- privacy-aware,
- technically capable,
- not childish,
- not corporate-generic,
- not overly playful.

Think:

```text
Apple Notes + Voice Memos + ChatGPT + meeting analyst
```

Not:

```text
AI toy with neon gradients and animated robots
```

---

## 4.2 Writing Style

Use short, clear, human text.

Good:

```text
Recording saved.
Transcription is still running.
```

Bad:

```text
Your conversational audio object has been persisted and the linguistic interpretation pipeline is executing.
```

Good:

```text
Audio stays on this iPhone.
```

Bad:

```text
Your privacy is important to us.
```

Good:

```text
Connect a provider to generate summaries.
```

Bad:

```text
No AI configuration found.
```

---

## 4.3 Naming Rules

Use user-facing names that map to the user's mental model.

Prefer:

- Meeting
- Recording
- Transcript
- Summary
- Tasks
- Decisions
- Questions
- Provider
- Model
- Local
- Remote

Avoid exposing internal names:

- `AIProviderConfig`
- `TranscriptionEngine`
- `TranscriptSegment`
- `MeetingAnalysis`
- `OpenAICompatibleProvider`

Internal names are fine in code, not in the UI.

---

## 5. Information Architecture

## 5.1 Recommended Top-Level Navigation

Use a bottom tab bar for the main sections.

Recommended MVP tab structure:

```text
Home
Meetings
Chat
Settings
```

### Home

Purpose:

- Start a meeting.
- Import audio.
- Continue latest meeting.
- See current setup status.

### Meetings

Purpose:

- Browse recorded meetings.
- Search meeting archive.
- Open meeting detail.

### Chat

Purpose:

- General provider-agnostic AI chat.
- Later: choose project/meeting context.

### Settings

Purpose:

- Providers.
- Transcription engines.
- Privacy modes.
- Storage.
- Developer/testing diagnostics.

This tab can remain during MVP because provider setup is central. Later, Settings may move behind a toolbar/profile button if the app becomes more consumer-polished.

---

## 5.2 Future Top-Level Navigation

When projects become important, consider:

```text
Home
Meetings
Projects
Chat
```

And move Settings to a toolbar button.

Do not add `Projects` as a top-level tab until it has real value.

---

## 5.3 Navigation Hierarchy

Recommended hierarchy:

```text
TabView
 ├── HomeView
 │    ├── ActiveRecordingView
 │    ├── ImportAudioView
 │    └── QuickSetupView
 │
 ├── MeetingsView
 │    ├── MeetingDetailView
 │    │    ├── SummaryView
 │    │    ├── TranscriptView
 │    │    ├── ActionItemsView
 │    │    ├── MeetingChatView
 │    │    └── MeetingMetadataView
 │    └── SearchResultsView
 │
 ├── ChatView
 │    ├── ConversationView
 │    └── ModelPickerView
 │
 └── SettingsView
      ├── ProviderListView
      ├── ProviderEditorView
      ├── TranscriptionSettingsView
      ├── PrivacySettingsView
      └── StorageSettingsView
```

---

## 6. Core User Flows

## 6.1 First Launch Flow

Goal:

Let the user get to value quickly.

Do not force a long onboarding slideshow.

Recommended first launch:

1. Show a simple welcome screen.
2. Explain the app in one sentence.
3. Offer two actions:
   - `Start with local recording`
   - `Configure AI provider`
4. Ask permissions only when needed.

Suggested copy:

```text
Capture meetings, turn them into summaries, and ask questions about what was said.
```

Primary button:

```text
Start a test recording
```

Secondary button:

```text
Set up AI provider
```

Avoid:

- 5-screen tutorials,
- abstract feature slides,
- forcing API setup before recording works,
- requesting microphone/speech permissions before the user starts a recording.

---

## 6.2 Start Meeting Flow

User path:

```text
Home -> Start Meeting -> Recording Screen -> Stop -> Processing -> Meeting Detail
```

Before starting:

- Ask for meeting title optionally.
- Allow default title based on date/time.
- Show active privacy mode.
- Show active transcription engine.

Do not block recording because provider is missing.

If no AI provider is configured:

```text
You can record now. Summaries can be generated after you connect a provider.
```

---

## 6.3 Active Recording Flow

The active recording screen must prioritize:

1. Recording status.
2. Timer.
3. Audio input confirmation.
4. Stop/Pause controls.
5. Important marker.
6. Current transcription preview if enabled.

Recommended hierarchy:

```text
[Recording badge]
00:14:32
Audio level meter

Live transcript preview...

[Mark Important]

[Pause] [Stop]
```

The stop button should require confirmation only if accidental stop is likely. Use a confirmation dialog:

```text
Stop recording?
The audio recorded so far will be saved.
```

Buttons:

- `Continue Recording`
- `Stop and Save`

---

## 6.4 Post-Recording Processing Flow

After the user stops recording:

1. Immediately confirm audio is saved.
2. Show progress stages.
3. Allow user to leave the screen if processing can continue.
4. Provide retry actions on failure.

Suggested stages:

```text
Audio saved
Preparing transcript
Transcribing
Generating summary
Extracting tasks
Ready
```

Use checkmarks for completed stages and a spinner/progress indicator for active stage.

If provider is missing:

```text
Audio saved. Connect a provider to generate a summary.
```

If transcription fails:

```text
Audio saved. Transcription failed. Retry or choose another transcription method.
```

---

## 6.5 Meeting Review Flow

Meeting detail should answer:

- What happened?
- What do I need to do?
- What was decided?
- Can I trust the AI output?
- Can I inspect the original transcript?

Recommended meeting detail tabs/sections:

```text
Summary
Transcript
Tasks
Ask
Info
```

For MVP, use a segmented control or horizontal section selector inside `MeetingDetailView`, not a nested tab bar.

---

## 6.6 Ask About Meeting Flow

The user opens a meeting and asks questions about that meeting.

The UI should make context explicit:

```text
Asking about: GLPR Batch Planning — May 25
```

Message input placeholder:

```text
Ask about this meeting...
```

Quick prompts:

- What were the decisions?
- What are my action items?
- What dates were mentioned?
- Draft a follow-up email.
- What was unclear?

The answers should include source links/timestamps where possible.

---

## 6.7 General Chat Flow

The general chat is not tied to a meeting unless the user chooses context.

Top bar should show:

- provider,
- model,
- privacy status if relevant.

Example:

```text
OpenAI-compatible · qwen-local · Local Network
```

If no provider is configured:

```text
Connect a provider to start chatting.
```

Provide direct link to provider setup.

---

## 6.8 Provider Setup Flow

Provider setup is technical, but the UI should still be clean.

Recommended structure:

```text
Provider name
Provider type
Base URL
API key
Default model
Advanced options
Test connection
Save
```

Provider type options:

- OpenAI-compatible
- OpenAI
- Anthropic
- Gemini
- Local network
- Future: Apple local

The test connection result should be human-readable:

```text
Connected. Model list loaded.
```

or:

```text
Could not connect to this provider. Check the URL and network access.
```

Do not show raw stack traces in normal UI.

---

## 7. Screen-by-Screen UX Specification

## 7.1 Home Screen

### Purpose

The Home screen is the launchpad.

It should make the app's value obvious in under 5 seconds.

### Required elements

- App title or greeting.
- Primary `Start Meeting` button.
- Secondary `Import Audio` action.
- Recent meeting card.
- Provider/transcription status summary.
- Optional quick chat entry.

### Layout sketch

```text
Home

[Start Meeting]   primary large button
[Import Audio]    secondary

Current setup
- Recording: Ready
- Transcription: Apple Speech
- Analysis: Not configured / Local network / OpenAI

Recent
[Meeting card]
[Meeting card]
```

### UX rules

- Start Meeting should be visually dominant.
- Provider setup should not visually compete with Start Meeting.
- Empty state should educate without lecturing.

Good empty state:

```text
No meetings yet.
Start a short test recording to see how summaries work.
```

---

## 7.2 Active Recording Screen

### Purpose

Support the user during a live meeting.

### Required elements

- Recording status badge.
- Large timer.
- Audio input indicator.
- Audio level meter or waveform.
- Transcription preview if enabled.
- Marker button.
- Pause button.
- Stop button.
- Local/remote processing indicator.

### Visual priority

1. Timer.
2. Recording state.
3. Stop/Pause.
4. Audio confirmation.
5. Transcript preview.
6. Secondary metadata.

### Critical UX details

The user must never wonder whether the app is recording.

Use:

- clear red recording indicator,
- timer changing every second,
- audio level movement,
- text label: `Recording`.

Do not rely only on a red dot.

### Marker button

Marker action should be fast and forgiving.

Recommended labels:

- `Mark Important`
- later: long press or menu for marker type.

When tapped:

```text
Important moment marked at 12:43
```

Use subtle haptic feedback.

---

## 7.3 Processing Screen

### Purpose

Reassure the user that data is safe and show what is happening.

### Required elements

- Audio saved confirmation.
- Processing pipeline.
- Progress/status per stage.
- Retry action on failure.
- Continue/review action when ready.

### Recommended UI

Use a vertical checklist:

```text
✓ Audio saved
✓ Transcript prepared
• Transcribing
○ Generating summary
○ Extracting tasks
```

### Failure handling

Do not use generic failure UI.

Examples:

```text
Audio saved. Could not transcribe.
Try again or choose another transcription method.
```

```text
Transcript saved. Could not generate summary.
Check provider settings or retry later.
```

---

## 7.4 Meetings List

### Purpose

Let users find, open, and manage meeting records.

### Required elements

- Search.
- Sort/filter later.
- Meeting cards/list rows.
- Empty state.

### Meeting row content

Each row should show:

- title,
- date/time,
- duration,
- processing status,
- summary preview or topic preview,
- privacy/engine badge if useful.

Example:

```text
GLPR Batch Jobs Discussion
Today, 10:04 AM · 48 min
Summary ready · 5 tasks · 2 decisions
```

### Row actions

Swipe actions can include:

- Delete
- Export
- Rename

Destructive actions require confirmation.

---

## 7.5 Meeting Detail

### Purpose

Turn raw recording into usable knowledge.

### Recommended top area

```text
Meeting title
Date · Duration · Project
[Local audio] [Remote analysis] [Summary ready]
```

### Sections

Use segmented control or top internal navigation:

```text
Summary | Transcript | Tasks | Ask | Info
```

### Summary tab

Show cards in this order:

1. Short summary.
2. Decisions.
3. Action items.
4. Open questions.
5. Risks/blockers.
6. Important dates.
7. Topics timeline.
8. Entities.

The short summary should be first because it gives immediate value.

### Transcript tab

Features:

- search within transcript,
- timestamped segments,
- speaker labels,
- tap timestamp to play audio,
- edit transcript action,
- original/edited indicator.

### Tasks tab

Show action items as task-like rows:

```text
[ ] Confirm deployment date
Owner: Robert · Due: Friday · Source: 12:45
```

Future actions:

- Add to Reminders.
- Mark done.
- Export tasks.

### Ask tab

Meeting-scoped chat.

Should be visually distinct from general chat by showing context:

```text
Context: This meeting only
```

### Info tab

Show:

- audio file status,
- transcript engine,
- analysis provider,
- privacy mode,
- storage location summary,
- export options,
- delete audio,
- delete meeting.

---

## 7.6 Transcript Editor

### Purpose

Allow corrections without destroying original data.

### UX rules

- Show edited status.
- Preserve original transcript.
- Allow save/cancel.
- Allow re-run analysis after edits.

Suggested copy:

```text
Editing the transcript will not change the original recording.
```

After save:

```text
Transcript updated. Re-run summary?
```

Actions:

- `Not now`
- `Re-run Summary`

---

## 7.7 Settings

### Purpose

Configure technical capabilities without overwhelming normal use.

### Sections

```text
Providers
Transcription
Privacy
Storage
Export
Developer Diagnostics
About
```

### Provider settings

Keep provider setup forms clean and explicit.

Use secure fields for API keys.

Show status:

- Connected
- Not tested
- Failed
- Missing API key

### Privacy settings

Show modes with explanation:

```text
Local first
Use local transcription when available. Send transcript to provider only for summaries.

Remote capable
Allow audio or transcript to be sent to selected providers.

Manual
Choose per meeting.
```

Avoid vague text.

---

## 8. Visual Design System

## 8.1 Overall Visual Direction

The visual style should be:

- native iOS,
- spacious,
- readable,
- quiet,
- utility-first,
- subtle depth,
- minimal custom styling,
- professional enough for work meetings.

Avoid:

- neon gradients,
- fake AI glow,
- heavy shadows,
- over-designed cards,
- dense enterprise dashboards,
- tiny status text,
- too many colors.

---

## 8.2 Typography

Use the system font through SwiftUI text styles.

Recommended styles:

| Purpose | SwiftUI style |
|---|---|
| Large screen title | `.largeTitle` |
| Section title | `.title2` or `.headline` |
| Card title | `.headline` |
| Body text | `.body` |
| Secondary metadata | `.subheadline` or `.caption` |
| Badges | `.caption` |
| Timer | `.largeTitle` or custom monospaced large style |

Use Dynamic Type.

Do not hard-code tiny text sizes for important information.

Timer recommendation:

```swift
.font(.system(size: 52, weight: .semibold, design: .rounded))
.monospacedDigit()
```

Use hard-coded timer size carefully and test with accessibility text sizes.

---

## 8.3 Color

Use semantic/system colors first.

Recommended semantic mapping:

| Meaning | Color approach |
|---|---|
| Primary action | `.accentColor` / `.tint` |
| Recording | system red |
| Success/saved | system green |
| Warning | system yellow/orange |
| Error | system red |
| Local/private | system green or blue badge |
| Remote/API | system purple or blue badge |
| Neutral metadata | secondary label color |
| Background | system background / grouped background |
| Cards | secondary system grouped background |

Rules:

- Support light and dark mode.
- Do not use color as the only indicator.
- Use text/icon along with color.
- Avoid custom color palettes until the product identity is stable.

---

## 8.4 Icons

Use SF Symbols.

Recommended icons:

| Concept | Symbol direction |
|---|---|
| Start recording | `mic.circle.fill` or `record.circle` |
| Active recording | `record.circle.fill` |
| Pause | `pause.circle.fill` |
| Stop | `stop.circle.fill` |
| Meeting | `calendar` or `person.2` |
| Transcript | `text.alignleft` |
| Summary | `doc.text` |
| Tasks | `checklist` |
| Decisions | `checkmark.seal` |
| Risks | `exclamationmark.triangle` |
| Questions | `questionmark.circle` |
| Provider | `network` or `server.rack` |
| Local | `iphone` |
| Remote | `cloud` |
| Local network | `wifi.router` |
| Privacy | `lock.shield` |
| Export | `square.and.arrow.up` |
| Settings | `gearshape` |

Rules:

- Pair icons with labels for important actions.
- Icons alone are acceptable only for common toolbar actions.
- Always provide accessibility labels.

---

## 8.5 Spacing

Use an 8-point spacing rhythm.

Recommended spacing tokens:

```swift
enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}
```

Common layout rules:

- screen horizontal padding: 16pt,
- card padding: 16pt,
- section spacing: 24pt,
- row vertical padding: 10-14pt,
- compact badge padding: 6-8pt horizontal.

---

## 8.6 Cards

Cards should group related information, not decorate everything.

Good card uses:

- summary block,
- action items,
- provider status,
- processing status,
- privacy mode,
- recent meeting.

Avoid making every row a heavy card.

Card style:

```swift
.background(.regularMaterial) // only where appropriate
.background(Color(.secondarySystemGroupedBackground))
.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
```

Use material sparingly. Prefer standard grouped backgrounds when possible.

---

## 8.7 Buttons

Use native button styles where possible.

Button hierarchy:

### Primary

Used for the main action.

Examples:

- Start Meeting
- Stop and Save
- Generate Summary
- Save Provider

### Secondary

Used for alternate actions.

Examples:

- Import Audio
- Test Connection
- Re-run Transcript

### Destructive

Used for deletion or irreversible actions.

Examples:

- Delete Meeting
- Delete Audio
- Remove Provider

Do not style destructive actions like normal primary buttons.

---

## 8.8 Badges and Status Pills

Use badges for compact status.

Examples:

- `Recording`
- `Saved`
- `Transcribing`
- `Summary ready`
- `Local`
- `Remote`
- `Hybrid`
- `Provider missing`

Badges should be readable and not too colorful.

Recommended structure:

```text
[icon] Label
```

Examples:

```text
[iPhone icon] Local
[Cloud icon] Remote analysis
[Lock icon] Audio on device
```

---

## 9. Component Library Specification

Claude Code should implement reusable SwiftUI components rather than repeating UI patterns in each screen.

## 9.1 AppStatusBadge

Purpose:

Show compact state.

Examples:

- Recording
- Saved
- Local
- Remote
- Error

Props:

```swift
struct AppStatusBadge: View {
    let title: String
    let systemImage: String?
    let tone: BadgeTone
}
```

Tones:

- neutral
- success
- warning
- error
- privacy
- recording

---

## 9.2 PrimaryActionButton

Purpose:

Consistent large primary buttons.

Examples:

- Start Meeting
- Generate Summary
- Save Provider

Props:

```swift
struct PrimaryActionButton: View {
    let title: String
    let systemImage: String?
    let isLoading: Bool
    let action: () -> Void
}
```

Rules:

- Minimum height: 50pt.
- Full width where appropriate.
- Clear disabled state.

---

## 9.3 EmptyStateView

Purpose:

Reusable empty states.

Props:

```swift
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let primaryActionTitle: String?
    let primaryAction: (() -> Void)?
}
```

Examples:

```text
No meetings yet.
Start a short test recording to see how summaries work.
```

---

## 9.4 ProcessingPipelineView

Purpose:

Show processing stages after recording.

Stages:

- audio saved,
- preparing transcript,
- transcribing,
- analyzing,
- extracting tasks,
- ready.

Props:

```swift
struct ProcessingPipelineView: View {
    let stages: [ProcessingStage]
}
```

Each stage:

```swift
struct ProcessingStage {
    let title: String
    let status: ProcessingStageStatus
}
```

Status:

- pending
- active
- complete
- failed

---

## 9.5 RecordingControlsView

Purpose:

Reusable recording control cluster.

Required actions:

- pause/resume,
- mark important,
- stop.

Rules:

- Stop must be clear.
- Mark Important must be fast.
- Pause should not look destructive.

---

## 9.6 AudioLevelMeterView

Purpose:

Show that microphone input is active.

Rules:

- Should be subtle.
- Should not imply professional audio editing precision.
- Must not be fake; if no audio data is available, show inactive state.

---

## 9.7 MeetingCard

Purpose:

Reusable meeting list item.

Content:

- title,
- date/time,
- duration,
- status,
- summary/task preview,
- badges.

---

## 9.8 InsightCard

Purpose:

Display extracted meeting intelligence.

Types:

- Summary
- Decision
- Action item
- Risk
- Question
- Date
- Entity

Rules:

- Important insights should have source timestamp if available.
- Long text should wrap cleanly.
- Do not overuse icons.

---

## 9.9 TranscriptSegmentRow

Purpose:

Display transcript segment.

Content:

- timestamp,
- speaker,
- text,
- confidence/edited indicator if needed.

Interaction:

- tap timestamp to play audio,
- long press for edit/copy/mark.

---

## 9.10 ProviderPicker

Purpose:

Choose provider/model cleanly.

Should display:

- provider name,
- model,
- local/remote status,
- connection status.

---

## 10. AI-Specific UX Rules

## 10.1 AI Output Should Be Structured

Do not dump raw AI text into the UI without structure.

Meeting analysis should appear as sections:

- Summary
- Decisions
- Action items
- Risks
- Open questions
- Dates
- Topics

Raw response may be stored for debugging but should not be the primary user experience.

---

## 10.2 Show Uncertainty Honestly

If the model is unsure, the UI should not hide it.

Examples:

```text
Owner unclear
Due date not mentioned
Possibly related to deployment
```

Avoid fake certainty.

---

## 10.3 Allow Regeneration, But Do Not Make It the Main UX

Regenerate is useful, but the app should not make the user feel like they are gambling for a better answer.

Use actions like:

- Re-run summary
- Analyze with another provider
- Re-run using edited transcript

Better than:

- Try again
- Make better
- Magic rewrite

---

## 10.4 Separate Chat from Artifacts

A chat response and a meeting artifact are different things.

If the user asks:

```text
Draft a follow-up email
```

The result should be saveable/copyable as an artifact, not only buried in chat history.

Future artifact types:

- follow-up email,
- Jira stories,
- formal minutes,
- task list,
- executive summary,
- project update.

---

## 10.5 Avoid Anthropomorphic Overreach

The app can be warm but should not pretend to be a person in productivity flows.

Prefer:

```text
Summary generated.
```

Avoid:

```text
I listened carefully and prepared this for you.
```

---

## 11. Privacy UX

## 11.1 Privacy Mode Display

Every meeting should show its processing mode.

Examples:

```text
Audio on device · Transcript sent to provider
```

```text
Audio and transcript stayed on this iPhone
```

```text
Audio sent to OpenAI for transcription
```

Do not use vague labels like `Secure Mode` without explanation.

---

## 11.2 Permission Prompts

Ask permissions just-in-time.

### Microphone

Ask when user starts first recording.

Pre-permission copy:

```text
Meeting AI needs microphone access to record your meeting.
Audio is saved on this iPhone unless you choose a remote transcription provider.
```

### Speech recognition

Ask when user starts transcription with Apple Speech.

Copy:

```text
Speech recognition is used to turn your recording into a transcript.
```

### Local network

Ask when user connects to LM Studio/Ollama/local provider.

Copy:

```text
Local network access lets the app connect to AI providers running on your own devices.
```

### Calendar/Reminders

Ask only when user uses those features.

---

## 11.3 Destructive Actions

Always confirm:

- Delete meeting.
- Delete audio.
- Delete transcript.
- Remove provider.
- Clear all data.

Confirmation copy should explain result:

```text
Delete audio?
The transcript and summary will remain, but you will not be able to replay the recording.
```

Buttons:

- Cancel
- Delete Audio

---

## 12. Accessibility Requirements

Accessibility is not optional. It is part of Apple-quality design.

## 12.1 Dynamic Type

All important text must support Dynamic Type.

Avoid fixed-size layouts that break when text grows.

Test with:

- default size,
- large accessibility size,
- bold text enabled.

---

## 12.2 VoiceOver

All interactive controls need meaningful labels.

Bad:

```text
Button, mic.circle.fill
```

Good:

```text
Start meeting recording
```

Recording controls should announce state:

```text
Recording, 12 minutes 43 seconds elapsed
```

---

## 12.3 Touch Targets

Interactive elements should be at least 44x44 points.

This is especially important for:

- recording controls,
- transcript timestamps,
- toolbar icons,
- badges that open details,
- play buttons.

---

## 12.4 Color and Contrast

Do not rely on color alone.

Bad:

```text
Red dot only means recording.
```

Good:

```text
Red dot + Recording text + running timer.
```

Support:

- light mode,
- dark mode,
- increased contrast,
- reduced transparency.

---

## 12.5 Motion

Use restrained animations.

Support Reduce Motion.

Avoid:

- constantly bouncing waveform,
- dramatic AI typing animations,
- excessive pulsing,
- motion that distracts during meetings.

---

## 13. Interaction Patterns

## 13.1 Sheets

Use sheets for:

- quick provider picker,
- import audio,
- marker type selection,
- export options,
- quick meeting title edit.

Do not put complex multi-step workflows into tiny sheets.

---

## 13.2 Confirmation Dialogs

Use for:

- stop recording confirmation if needed,
- destructive actions,
- switching provider during active process,
- deleting audio.

---

## 13.3 Context Menus

Use on:

- transcript segment rows,
- meeting cards,
- action items,
- AI response blocks.

Possible actions:

- Copy
- Play from here
- Mark important
- Edit segment
- Add to tasks

---

## 13.4 Pull to Refresh

Useful for:

- provider model list,
- meeting processing status if background processing exists.

Not needed for local static lists unless it maps to real refresh behavior.

---

## 13.5 Search

Use search in:

- Meetings list,
- Transcript view,
- Projects later.

Search should support plain text first.

Do not jump to semantic search before exact/local search works.

---

## 14. Error and Empty State Patterns

## 14.1 Error Message Formula

Good error messages include:

1. What happened.
2. What was preserved.
3. What the user can do.

Example:

```text
Summary failed.
Your recording and transcript are saved. Check provider settings or try again.
```

---

## 14.2 Common Error States

### Microphone denied

```text
Microphone access is off.
Turn it on in Settings to record meetings.
```

Action:

```text
Open Settings
```

### Provider missing

```text
No AI provider configured.
You can still record meetings. Connect a provider to generate summaries.
```

Action:

```text
Set Up Provider
```

### Local network unavailable

```text
Could not reach local provider.
Make sure your iPhone and Mac are on the same Wi‑Fi network.
```

### Transcription failed

```text
Audio saved. Transcription failed.
Try again or choose another transcription method.
```

### Analysis failed

```text
Transcript saved. Summary generation failed.
Retry or choose another provider.
```

---

## 14.3 Empty States

### No meetings

```text
No meetings yet.
Record a short test meeting to create your first summary.
```

### No provider

```text
No provider connected.
Add an API provider or local network model to generate summaries and chat responses.
```

### No transcript yet

```text
Transcript not ready.
You can retry transcription or review the saved audio.
```

### No action items

```text
No clear action items found.
You can ask the meeting chat to look again or add one manually.
```

---

## 15. Onboarding Strategy

## 15.1 Recommended Approach

Use minimal onboarding.

The user should learn by doing.

Recommended first-run actions:

1. Start test recording.
2. Configure provider.
3. Import audio.

No long tutorial unless the app becomes complex enough to justify it.

---

## 15.2 Setup Checklist

Instead of a tutorial, use a small checklist on Home:

```text
Setup
✓ Recording ready
○ Transcription permission
○ AI provider connected
```

Each item opens the relevant setup screen.

This gives clarity without blocking the user.

---

## 15.3 Sample Data

Optional later:

Provide a sample meeting transcript so the user can see the analysis UI without recording.

This is useful for testing and demo mode.

Do not include sample data in a way that confuses it with user data.

---

## 16. iPhone 14 Plus Layout Considerations

The iPhone 14 Plus has a large screen, but it is still a phone.

UX implications:

- Use the extra vertical space for clarity, not density.
- Do not create desktop-style dashboards.
- Keep primary controls reachable.
- Avoid putting important actions only in the top-right toolbar.
- Use bottom-positioned primary actions when appropriate.
- Test one-handed usability for recording controls.

Recording controls should be near the bottom.

Meeting detail can use large readable sections.

Transcript should prioritize readability over showing many segments at once.

---

## 17. Motion and Haptics

## 17.1 Haptics

Use subtle haptics for:

- recording started,
- marker added,
- recording stopped,
- action item checked,
- error if important.

Avoid excessive haptics during live transcription.

---

## 17.2 Animation

Use animation to clarify state changes, not to decorate.

Good:

- processing stage completes,
- new transcript segment appears,
- marker confirmation appears,
- summary card expands.

Bad:

- constant animated AI avatar,
- pulsing everything,
- long transitions during active meeting.

---

## 18. Design Patterns to Avoid

Avoid these unless explicitly justified:

1. Chat as the only interface for everything.
2. Raw transcript as the default meeting result.
3. Long onboarding before first value.
4. Hidden recording status.
5. Provider configuration mixed into recording screen.
6. Raw JSON in user-facing screens.
7. Fake local/remote privacy labels.
8. Custom UI controls that break accessibility.
9. Dense settings before MVP is useful.
10. Large local-AI marketing promises on iPhone 14 Plus.
11. Multiple primary buttons on one screen.
12. Deleting raw audio as part of normal cleanup without explicit confirmation.
13. Treating AI output as unquestionable.

---

## 19. SwiftUI Implementation Guidelines for UI

## 19.1 View Structure

Use small views with clear responsibilities.

Good:

```text
HomeView
MeetingCard
RecordingControlsView
ProcessingPipelineView
MeetingSummaryView
TranscriptSegmentRow
ProviderSettingsView
```

Bad:

```text
ContentView with everything
```

---

## 19.2 View Models

Use view models for UI state.

Do not call audio/transcription/networking logic directly from SwiftUI views except through injected services.

Example:

```swift
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var state: RecordingState
    @Published var elapsedTime: TimeInterval
    @Published var audioLevel: Float

    private let audioCaptureService: AudioCaptureService
}
```

---

## 19.3 Preview Data

Create preview/sample data for UI components.

Required preview states:

- no meetings,
- one recent meeting,
- active recording,
- processing success,
- processing failure,
- provider missing,
- transcript with segments,
- summary with decisions/tasks,
- dark mode,
- large text.

Claude Code should not build UI without previewable states.

---

## 19.4 Design Tokens

Create a small design token layer.

Example:

```swift
enum AppSpacing { ... }
enum AppRadius { ... }
enum AppCopy { ... }
```

Do not overbuild a design system before screens exist, but do centralize repeated values.

---

## 20. UX Acceptance Criteria

A screen is acceptable only if:

1. The primary action is obvious.
2. The user can understand the current state.
3. The user can recover from errors.
4. The user knows whether data is local or remote when relevant.
5. It supports dark mode.
6. It supports Dynamic Type reasonably.
7. It has meaningful empty states.
8. It avoids raw technical internals unless in developer settings.
9. It uses native iOS patterns unless there is a clear reason not to.
10. It does not compromise recording safety.

---

## 21. MVP UI Scope

## 21.1 Must Build in MVP 1

- Tab shell.
- Home screen.
- Start recording screen.
- Active recording screen.
- Processing status screen.
- Meetings list.
- Meeting detail summary view.
- Transcript view basic.
- Provider setup screen.
- Settings screen.
- Export/share flow.
- Empty/error states.

## 21.2 Should Not Build in MVP 1

- Full project dashboard.
- Advanced calendar UI.
- Widgets.
- Live Activities.
- Cloud sync UI.
- Complex analytics charts.
- Speaker voice profiles.
- Large custom design system.
- Full AI artifact workspace.
- Apple Intelligence-specific UI.

## 21.3 MVP 1 UX Success

The MVP is successful if the user can:

1. Open the app.
2. Start a recording.
3. Stop and save it.
4. Get a transcript.
5. Generate a summary.
6. Review summary and transcript.
7. Export the result.
8. Understand what was processed locally/remotely.

---

## 22. Future UX Roadmap

## Phase 2 UX

- Better meeting detail.
- Transcript editing.
- Audio playback by timestamp.
- Import audio polish.
- Re-transcribe with different engine.
- Manual markers UI.
- Local search.

## Phase 3 UX

- Project-based views.
- Meeting comparison.
- Calendar association.
- Reminders export.
- OCR attachment flow.
- Better meeting-scoped chat.

## Phase 4 UX

- Widgets.
- Live Activities.
- Shortcuts/App Intents.
- Mac/iPad layout adaptation.
- Semantic memory.
- Local/offline mode dashboard.

---

## 23. Claude Code Instructions for UX/UI Work

When implementing UI, Claude Code must:

1. Read this manual before creating screens.
2. Prefer SwiftUI native components.
3. Keep views small and previewable.
4. Use reusable components for badges, cards, empty states, processing stages, transcript rows, and buttons.
5. Implement dark mode naturally with system colors.
6. Avoid hard-coded colors unless they represent semantic status.
7. Avoid fake data in production paths.
8. Provide preview data for visual testing.
9. Keep business logic out of views.
10. Update this manual when a UI decision changes.

For any new screen, Claude should answer before coding:

```text
What is the primary action?
What is the main state the user needs to understand?
What are the empty/error states?
What data is local or remote?
What reusable components should be used?
```

---

## 24. UI Quality Review Checklist

Before considering UI work complete, check:

### Navigation

- Is the screen reachable through a clear path?
- Is back navigation predictable?
- Are tabs used only for top-level sections?
- Are sheets used for focused tasks only?

### Layout

- Does it work on iPhone 14 Plus?
- Does it avoid unnecessary density?
- Are primary controls reachable?
- Is there enough spacing?

### Content

- Is the text clear?
- Are technical terms hidden unless needed?
- Are empty states useful?
- Are error messages actionable?

### Accessibility

- Does Dynamic Type work?
- Are touch targets large enough?
- Are icons labeled?
- Is color not the only indicator?
- Does dark mode work?

### AI Trust

- Is AI output structured?
- Is uncertainty represented honestly?
- Can important claims link back to transcript evidence later?
- Does the app show local/remote processing status?

### Recording Safety

- Is recording status unmistakable?
- Does the app confirm audio is saved?
- Can the user recover from transcription/analysis failure?
- Are destructive actions confirmed?

---

## 25. Final Design Direction

The app should feel like this:

```text
A native iPhone meeting intelligence tool that quietly captures, organizes, and explains conversations.
```

It should not feel like:

```text
A chatbot with a record button glued on.
```

The UX should make recording reliable, summaries useful, transcript evidence accessible, providers configurable, and privacy understandable.

The design should be polished but not flashy.

The user should trust it during a real meeting.

