# App Store Metadata — Wawa Note 1.0

Verified: July 19, 2026

Related JIRA: KAN-70, KAN-71, KAN-540

This file is the source of truth for the first App Store submission. It describes only the three-tab v1 product that is reachable in the shipping UI: Capture, Inbox, and Explore. Chat, graph, task-board, and project-health features are not part of the v1 listing.

## Product page

### App name

Wawa Note

Length: 9 of 30 characters.

### Subtitle

Record, transcribe, organize

Length: 28 of 30 characters.

### Promotional text

Capture meetings, notes, scans, and imports in one local-first workspace. Transcribe on device, organize with projects, and use optional AI on your terms.

Length: 154 of 170 characters.

### Description

Wawa Note is a local-first workspace for capturing and organizing the material behind your work. Record a meeting, turn it into searchable text, scan a document, write a note, or import a file—then keep related items together in a project.

CAPTURE IN ONE PLACE
• Record meetings and conversations you choose to capture
• Scan multi-page documents and extract their text
• Create notes and web bookmarks
• Import PDF, Markdown, JSON, HTML, RTF, ICS, SRT, and other supported files
• Send compatible content from other apps with the Share extension

FIND AND ORGANIZE
• Search and filter your complete local library from Inbox
• Group related recordings, notes, scans, and imports into simple projects
• Explore project activity and revisit source material
• Recover recently deleted items from Trash or remove them permanently

TRANSCRIBE ON DEVICE
Apple Speech is configured for on-device transcription by default, so core capture and organization work without an AI account or API key. Original recordings and transcripts remain available until you delete them.

OPTIONAL AI, YOUR CHOICE
If you want summaries and structured analysis, connect a supported AI service with your own API key or use a compatible model on a computer you control. Cloud processing is blocked until you approve a named provider and can be revoked at any time.

LOCAL-FIRST BY DESIGN
Wawa Note has no account, advertising, analytics, tracking, or Wawa Note cloud backend. Your library is stored on your iPhone. API keys are kept in the iOS Keychain. Export your data when you want to use it elsewhere.

No cloud AI service is required. Network-provider charges and terms, if any, come from the provider you choose.

### Keywords

meeting,recorder,transcript,notes,voice,scanner,OCR,projects,organizer,knowledge,offline,privacy

Length: 96 of 100 bytes. App and company names are intentionally omitted.

### URLs

- Support URL: `https://github.com/wsmontes/wawa-note-ios/blob/main/SUPPORT.md`
- Marketing URL: `https://github.com/wsmontes/wawa-note-ios`
- Privacy Policy URL: `https://github.com/wsmontes/wawa-note-ios/blob/main/PRIVACY.md`
- Privacy Choices URL: use the Privacy Policy URL; in-app controls are at Settings > Privacy & Data Controls

The public website at `https://wawasoft.net/wawa-note/` is not suitable for the v1 metadata until its Chat, graph, and task-board claims are removed.

### Classification

- Primary category: Productivity
- Secondary category: Business
- Price: Free
- Copyright: 2026 Wawasoft BC LTD
- Version: 1.0
- Release: Manual release after approval
- Distribution: Public; initial availability in Canada and the United States
- Tax category: App Store software
- Made for Kids: No

## Age rating questionnaire

The v1 app is a private productivity tool. It does not distribute user-generated content, offer person-to-person chat, provide unrestricted web browsing, show advertising, or contain built-in mature media. Answer **None/No** for all content descriptors and capabilities unless App Store Connect presents a new question that materially differs from Apple's current definitions. This should produce a 4+ global rating.

Do not mark personal notes, recordings, or imported material as “User-Generated Content” for this questionnaire: Apple defines that capability around broad distribution inside the app, which Wawa Note does not provide.

## Content rights

Answer **Yes** when asked whether the app can access third-party content because users can save web pages and import documents. Confirm that the app is authorized to access content supplied by the user. The app does not provide a public content catalogue or redistribute imported material.

## Export compliance

- The app uses HTTPS, Keychain, and other encryption supplied by Apple's operating system.
- It does not implement or bundle proprietary or non-exempt encryption.
- `ITSAppUsesNonExemptEncryption` is `false` in the shipping app's Info.plist.
- No export-compliance documentation is expected to be required; answer the App Store Connect questionnaire consistently with these facts.

## App privacy questionnaire

Use `docs/privacy-nutrition-labels.md` exactly. In summary:

- Data collected: Yes
- Audio Data: App Functionality; linked; not tracking
- Photos or Videos: App Functionality; linked; not tracking
- Other User Content: App Functionality; linked; not tracking
- Privacy policy is accessible both in metadata and in Settings > Privacy & Data Controls

## Accessibility nutrition labels

Do not publish an accessibility-support claim until the corresponding common-task matrix has passed on the release build. The initial audit must cover first launch, capture, save, search, project grouping, item review, deletion, export, and Settings. At minimum, evaluate VoiceOver, Voice Control, Larger Text, Dark Interface, Differentiate Without Color Alone, Sufficient Contrast, and Reduced Motion.

## App Review notes

Wawa Note 1.0 is a local-first iPhone capture and organization app. No account, subscription, purchase, or reviewer login is required.

The shipping interface has three tabs:
1. Capture — record audio, scan a document, create a note or bookmark, or import a file.
2. Inbox — search, filter, review, move, delete, and restore source items.
3. Explore — create simple projects and group related items together.

Core functionality works without an API key. Apple Speech is set to on-device recognition by default. To inspect optional provider configuration, open the gear button from Capture, then AI Services. A cloud provider is blocked from receiving content until the user enables the provider-specific, off-by-default sharing approval. Settings > Privacy & Data Controls shows current approvals and explains how to revoke them.

The app requests permissions only from the feature that needs them:
- Microphone and Speech Recognition when the reviewer starts recording/transcription.
- Camera when the reviewer starts document scanning (camera is unavailable in Simulator).
- Local Network when the reviewer chooses an on-computer AI service or taps Scan Network in AI Services.
- Calendar, Reminders, Contacts, and Face ID only when the corresponding optional integration is used.

Recording always begins from an explicit user action and displays an active recording interface. The app has no advertising, analytics, tracking, or Wawa Note backend. Optional cloud AI requests use a reviewer-supplied provider credential; no credential is included in the binary.

Privacy policy: https://github.com/wsmontes/wawa-note-ios/blob/main/PRIVACY.md
Support: wawasoftbc@gmail.com

## Screenshot submission plan

Upload five English (U.S.) portrait screenshots at an accepted 6.9-inch size. A single highest-resolution set can scale down for other supported iPhones.

1. **Capture what matters** — Capture tab with Record, Scan Document, and other creation options visible.
2. **Your work, searchable** — Inbox with several clearly fictional items and search/filter controls.
3. **Keep related items together** — Explore with two or three fictional projects.
4. **Review every source** — A project or item detail view showing source material and transcript/analysis without personal data.
5. **Local-first by design** — Privacy & Data Controls showing no cloud provider configured and Apple cloud speech Off.

Requirements:

- Use fictional, non-sensitive demo content only.
- Capture from a clean release-equivalent build with no debug overlays.
- Use PNG without alpha.
- Preferred portrait size: 1320 × 2868 pixels (accepted 6.9-inch size).
- Do not show Chat, a knowledge graph, a task board, project health, Watch UI, or any feature not reachable in v1.
- Validate every final image's pixel dimensions, color mode, and absence of alpha before upload.

An app preview video is intentionally deferred for 1.0.

## Submission checklist

- [ ] Public `PRIVACY.md` and `SUPPORT.md` are reachable from the exact URLs above on the submitted branch.
- [ ] App Store privacy responses match `docs/privacy-nutrition-labels.md` and the packaged privacy manifest.
- [x] Five upload-ready screenshots pass the requirements above (`docs/app-store/screenshots/en-US`).
- [ ] Accessibility claims are either tested and accurate or left unpublished.
- [ ] Build 1.0 (7) is selected and its export-compliance answer is accepted.
- [ ] Review contact name, phone, and email are current in App Store Connect.
- [ ] Manual release and initial Canada/United States availability are selected.
