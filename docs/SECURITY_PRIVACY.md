# Security and Privacy — AI Meeting Companion iOS

## 1. Privacy principle

The user must always understand what stays on device and what leaves the device.

The app handles sensitive content:

- Meeting audio.
- Transcripts.
- Summaries.
- Action items.
- People and organization names.
- API keys.

## 2. Processing modes

Implement these concepts in the product model even if only some are available in MVP:

| Mode | Meaning |
|---|---|
| Fully local | Audio, transcript, and analysis stay local. |
| Local transcription + remote analysis | Audio stays local, transcript goes to provider. |
| Remote transcription + remote analysis | Audio and transcript may leave device. |
| Manual | User chooses engine per step. |

MVP likely supports:

```text
Local audio + Apple transcription + remote/local-network AI analysis
```

## 3. API keys

Rules:

- Store API keys in Keychain only.
- Do not store API keys in SwiftData.
- Do not store API keys in JSON.
- Do not print API keys in logs.
- Do not show full API key after saving.
- Provider config stores only the Keychain identifier.

## 4. Local files

Audio and meeting artifacts should live under Application Support, not random Documents paths unless user exports them.

Recommended:

```text
Application Support/Meetings/{meetingId}/
```

## 5. Raw audio deletion

User should be able to delete raw audio while keeping transcript and analysis.

When raw audio is deleted:

- Remove audio file.
- Keep transcript.
- Keep analysis.
- Mark meeting as no longer having audio.

## 6. Permissions

Expected permissions:

- Microphone.
- Speech recognition.
- Local network for LAN providers.
- Photos later for OCR attachments.
- Calendar/Reminders later.
- Contacts later.

Permission text should be specific.

Example microphone text:

```text
This app uses the microphone to record meetings you choose to capture.
```

Example speech recognition text:

```text
This app uses speech recognition to transcribe your recorded meetings.
```

Example local network text:

```text
This app uses your local network to connect to AI providers running on your own devices, such as LM Studio or Ollama on your Mac.
```

## 7. Face ID / LocalAuthentication

Not MVP-required, but later recommended for:

- Opening sensitive meeting archive.
- Viewing API key settings.
- Exporting sensitive meeting content.

## 8. Encryption

MVP:

- Rely on iOS sandbox for local files.
- Keychain for secrets.

Later:

- Use CryptoKit to encrypt meeting artifacts.
- Store per-meeting symmetric key in Keychain.
- Consider optional “encrypted meeting” mode.

## 9. Logging

Logs must not include:

- API keys.
- Authorization headers.
- Full raw transcript by default.
- Full provider responses by default if sensitive.

Debug mode can preserve raw provider response to file only when explicitly needed.

## 10. Network calls

For provider calls, show clear status:

- local
- local network
- remote API

The app should not silently send audio or transcript to remote services.

## 11. Apple Intelligence constraint

Do not depend on Apple Foundation Models for iPhone 14 Plus. Treat them as optional on supported devices only.
