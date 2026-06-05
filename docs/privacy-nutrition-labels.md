# App Privacy Labels — Wawa Note

## Data Not Collected

The following data types are NOT collected by Wawa Note:

| Data Type | Reason |
|-----------|--------|
| **Contact Info** (name, email, phone) | No account required |
| **Health & Fitness** | Not used |
| **Financial Info** | Not used |
| **Location** | Optional context sensor — stays on device |
| **Sensitive Info** | Not used |
| **Contacts** | Optional speaker matching — stays on device |
| **User Content** (audio, photos, documents) | Stored on device only |
| **Browsing History** | Not used |
| **Search History** | Not used |
| **Identifiers** (user ID, device ID) | Not collected |
| **Purchases** | Not used |
| **Usage Data** (product interaction, advertising) | Not collected |
| **Diagnostics** (crash logs, performance) | Stored on device only — user optionally shares via Settings |
| **Other Data** | Not collected |

## Data That MAY Be Sent to Third Parties

Users OPTIONALLY configure their own AI provider API keys. When enabled:
- **Audio recordings** may be sent to the user's configured transcription provider (e.g., OpenAI Whisper API)
- **Text content** may be sent to the user's configured AI provider for analysis and chat

These are user-controlled decisions. Wawa Note itself does not collect, store, or transmit any data.

## Privacy Policy Summary

Wawa Note is a local-first app. All data is stored on-device using SwiftData and FileManager. API keys are stored in the Keychain. The app never communicates with any server except those explicitly configured by the user (AI providers). No analytics, no tracking, no telemetry.
