# Test Plan — AI Meeting Companion iOS

## 1. Test device

Primary real-device target:

```text
iPhone 14 Plus
```

Simulator is useful for UI and storage. Real device is required for meaningful audio, microphone, speech recognition, background behavior, and battery testing.

## 2. Build tests

Claude Code should run an equivalent of:

```bash
xcodebuild -scheme <SCHEME_NAME> -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build
```

If the actual simulator name differs, inspect available destinations.

## 3. Unit tests

Candidate unit tests:

- FileArtifactStore creates meeting folder.
- FileArtifactStore writes/reads JSON.
- SecureKeyStore saves/loads/deletes test secret.
- Provider config does not expose API key.
- OpenAICompatibleProvider builds correct request from internal `AIRequest`.
- Analysis parser handles valid JSON.
- Analysis parser preserves raw response when JSON is invalid.
- Markdown exporter produces readable file.

## 4. Manual MVP tests

## 4.1 Recording reliability

Test cases:

- Record 30 seconds.
- Record 5 minutes.
- Record 15 minutes.
- Record 60 minutes.
- Stop recording normally.
- Interrupt recording with phone lock.
- Interrupt recording with another audio event if possible.
- Change audio route if possible.

Expected:

- Audio file is created.
- Meeting metadata is saved.
- App does not lose state.
- App can recover or show clear failure.

## 4.2 Transcription quality

Test cases:

- English meeting-style speech.
- Portuguese speech.
- Mixed English/Portuguese.
- Technical vocabulary.
- Background noise.

Expected:

- Transcript is usable.
- Error is recoverable.
- Transcript is saved.
- Segment timestamps are preserved when available.

## 4.3 Provider analysis

Test cases:

- Valid OpenAI-compatible provider.
- Wrong API key.
- Wrong base URL.
- Network unavailable.
- Provider returns non-JSON.
- Provider returns valid structured JSON.

Expected:

- Success path saves analysis.
- Failures show useful messages.
- Raw response is preserved when parsing fails.
- API key is not logged.

## 4.4 Export

Test cases:

- Export Markdown.
- Export JSON.
- Share to Files.
- Share to Notes/Mail if available.

Expected:

- Exported files are readable.
- Transcript and summary appear in export.
- No API key appears in export.

## 5. iPhone 14 Plus experiments

## Experiment 1 — Native recording

Record:

- 5 minutes foreground.
- 15 minutes foreground.
- 60 minutes foreground.
- screen-lock scenario.

Capture:

- success/failure
- battery impact
- thermal behavior
- file size
- interruption behavior

## Experiment 2 — Apple transcription

Try:

- short audio
- meeting-like audio
- technical terms
- mixed language

Capture:

- speed
- quality
- timestamps
- failures

## Experiment 3 — Local network provider

Test:

- LM Studio or compatible server on Mac.
- iPhone connects over Wi-Fi.
- Use LAN IP, not `localhost`.
- Later test Bonjour discovery.

Capture:

- connectivity
- local network permission prompt
- response latency
- streaming feasibility

## Experiment 4 — WhisperKit later

Not MVP 1.

When added, test:

- tiny model
- base model
- small model
- 10-minute audio
- 60-minute audio
- heat/battery

## 6. Regression checklist

Before declaring a phase complete:

- App builds.
- App launches.
- Existing meeting list still works.
- Existing provider config still works.
- No secrets are printed.
- No large binary files are accidentally committed.
- `docs/TASKS.md` updated.
- `docs/DECISIONS.md` updated if needed.
