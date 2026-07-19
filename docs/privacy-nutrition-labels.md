# App Privacy Labels — Wawa Note

Verified: July 19, 2026

Related JIRA: KAN-71

This file is the source of truth for the App Store Connect questionnaire. It intentionally uses a conservative interpretation of provider retention: a built-in cloud AI provider can retain an API request beyond real-time servicing and can associate it with the account represented by the user's API key.

## App Store Connect answers

Answer **Yes** to “Does this app collect data?” and declare:

| App Store data type | Collected | Linked to user | Tracking | Purpose | When |
|---|---:|---:|---:|---|---|
| User Content > Audio Data | Yes | Yes | No | App Functionality | Only when remote transcription is enabled and approved |
| User Content > Photos or Videos | Yes | Yes | No | App Functionality | Only when an approved cloud vision request includes an image or scan |
| User Content > Other User Content | Yes | Yes | No | App Functionality | Only when approved cloud AI analyzes transcripts, notes, scans, imports, or derived text |

“Linked to user” is **Yes** because a user-supplied API key can link a request to that person's account at the selected provider. Wawa Note itself has no account system.

Do not declare any category as used for advertising, marketing, analytics, product personalization, or tracking.

## Data that remains on device

The following is not “collected” under Apple's definition when it stays entirely on device:

- the local SwiftData library and file artifacts;
- on-device Apple Speech transcripts and Vision OCR output;
- calendar events, reminders, contacts, and Face ID results;
- local search history and locally generated diagnostics;
- content sent only to a model on a computer controlled by the user.

Local-network permission is requested only when the user opens local-model discovery or connects a local endpoint. Local HTTP is allowed only through the scoped `NSAllowsLocalNetworking` ATS exception; arbitrary remote HTTP remains blocked.

The app has no first-party analytics, advertising SDK, telemetry endpoint, Wawa Note account, or cloud backend. Debug logs leave the device only when the user explicitly exports and shares a copy.

## Manifest alignment

`wawa-note/Resources/PrivacyInfo.xcprivacy` declares the same three optional collected-data categories, all for `NSPrivacyCollectedDataTypePurposeAppFunctionality`, linked, and not used for tracking. Required-reason APIs are limited to categories confirmed in current source:

- UserDefaults — `CA92.1`;
- file timestamps — `C617.1`;
- disk space — `E174.1`.

## Public policy and controls

- Privacy policy: `https://github.com/wsmontes/wawa-note-ios/blob/main/PRIVACY.md`
- In app: Settings > Privacy & Data
- Revoke cloud AI: Settings > AI Services > provider > Edit, then disable content sharing or delete the provider
- Delete local content: Inbox > Trash > Empty Trash
