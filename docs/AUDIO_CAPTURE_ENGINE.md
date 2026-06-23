# Audio Capture Engine — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-73, KAN-79
**Source modules:** `Audio/`

---

## Overview

The audio capture engine records meetings as PCM WAV, handles interruptions and route changes, and provides crash-safe file writing with disk space monitoring. It is the most hardware-sensitive subsystem — directly interfacing with AVAudioEngine, AVAudioSession, and the device's microphone hardware.

---

## Architecture

```
┌──────────────────────────────────────┐
│       AudioCaptureService            │
│  States: idle, recording, paused,    │
│          stopped                     │
│  Tap callback → PCM float32 samples  │
│  Adaptive gain control               │
│  Silence detection (60s threshold)   │
└──────────────┬───────────────────────┘
               │
    ┌──────────▼──────────┐
    │  AudioSessionManager │
    │  AVAudioSession      │
    │  Route management     │
    │  Interruption handler │
    │  Disk space check     │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────┐
    │  AudioFileWriter      │
    │  PCM WAV segments     │
    │  Manifest management  │
    │  Checkpoint every 5s  │
    │  Retry with recovery   │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────────┐
    │ AudioSegmentConcatenator │
    │  Merge segments → .m4a  │
    └─────────────────────────┘
               │
    ┌──────────▼──────────┐
    │  AudioPlaybackService │
    │  AudioPlayer          │
    │  NowPlayingController │
    └──────────────────────┘
```

---

## AudioCaptureService

### State machine

```
idle ──► recording ──► paused ──► recording ──► stopped ──► idle
  │                     │
  └── (error) ────► stopped
```

### Recording lifecycle

1. **startRecording()**
   - Check `availableDiskSpace` (threshold: 50MB + estimated recording size)
   - Configure AVAudioSession (playAndRecord, allowBluetooth)
   - Install tap on AVAudioEngine input node
   - Set `state = .recording`

2. **Tap callback** (called every ~23ms at 44.1kHz)
   - Receive `AVAudioPCMBuffer` (float32, mono)
   - Apply adaptive gain control
   - Check silence threshold (60s → pause warning)
   - Dispatch to `AudioFileWriter.write(samples:frameLength:format:)`

3. **pauseRecording()**
   - Stop tap → keep session active
   - `state = .paused`

4. **resumeRecording()**
   - Reinstall tap
   - `state = .recording`

5. **stopRecording()**
   - Remove tap
   - `AudioFileWriter.finishRecording()`
   - `AudioSegmentConcatenator.concatenate()` → `audio.m4a`
   - Deactivate AVAudioSession
   - `state = .stopped`

### Adaptive gain control
- Tracks peak amplitude over rolling 5-second window
- Adjusts gain to keep peaks in [-6dB, -3dB] range
- Prevents clipping while maintaining good signal level

### Silence detection
- If RMS amplitude < threshold for 60 consecutive seconds → `onSilenceDetected` callback
- UI shows "Paused — silence detected"
- User can resume or stop

---

## AudioSessionManager

### Route change handling
When the audio route changes (Bluetooth headset connected/disconnected, wired headphones plugged/unplugged), the engine must be rebuilt.

1. Notification: `AVAudioSession.routeChangeNotification`
2. Check reason: `.newDeviceAvailable`, `.oldDeviceUnavailable`, `.override`
3. If recording is active:
   - Remove tap from old input node
   - Reconfigure AVAudioSession for new route
   - Reinstall tap on new input node
   - Log route change event
4. Fallback: if Bluetooth fails, force built-in mic

### Interruption handling
1. `AVAudioSession.interruptionNotification`
2. `.began` (phone call, Siri, alarm):
   - `AudioCaptureService.pauseRecording()`
   - Save checkpoint to file
3. `.ended` with `.shouldResume`:
   - `AudioCaptureService.resumeRecording()`
4. `.ended` without `.shouldResume`:
   - `AudioCaptureService.stopRecording()` (force finish)

### Disk space guard
```swift
func checkDiskSpace(estimatedDuration: TimeInterval) -> Bool {
    let requiredBytes = sampleRate * 4 * estimatedDuration  // 44.1kHz × 4 bytes × seconds
    let available = FileManager.default.volumeAvailableCapacity(forImportantUsage: .user)
    return (available ?? 0) > Int64(requiredBytes + 50_000_000)  // 50MB safety margin
}
```

---

## AudioFileWriter

### PCM WAV segment writing
- Each segment: PCM float32, mono, 44.1kHz, WAV container
- Segments written to `items/<uuid>/segments/segment_NNN.wav`
- Manifest: `items/<uuid>/segments/manifest.json` tracks segment order

### Crash-safe checkpointing
- Every 5 seconds, write a checkpoint marker to the manifest
- On app launch, scan for incomplete manifests → recover segments
- If checkpoint marker exists, all segments up to that point are valid

### Write retry with recovery
```swift
func write(samples: AVAudioPCMBuffer, frameLength: AVAudioFrameCount, format: AVAudioFormat) {
    queue.async {
        var attempt = 0
        let maxAttempts = 4
        while attempt < maxAttempts {
            do {
                try self.audioFile.write(from: samples)
                return // Success
            } catch {
                attempt += 1
                if attempt >= maxAttempts {
                    self.onWriteFailure?(error)
                    return
                }
                // Exponential backoff: 0.1s, 0.2s, 0.4s
                Thread.sleep(forTimeInterval: 0.1 * pow(2.0, Double(attempt - 1)))
            }
        }
    }
}
```

### Known issue (TODO_FILE_MANAGEMENT.md #2)
`Thread.sleep` inside serial queue blocks all subsequent writes. Fix: use `queue.asyncAfter` or work-stealing pattern.

### Disk full detection
- Distinguish transient error (file handle busy) from permanent error (disk full)
- `NSCocoaErrorDomain` + `NSFileWriteOutOfSpaceError` → abort immediately, no retry
- Call `onWriteFailure` → `AudioCaptureService.forceFinish()`

---

## AudioSegmentConcatenator

Merges all segment WAV files into a single `audio.m4a`:

1. Read `manifest.json` for segment list
2. Open each `segment_NNN.wav`, read PCM data
3. Concatenate in order
4. Write merged WAV
5. Convert to M4A (AAC) for storage efficiency
6. Delete segment files on success
7. On failure → keep segments, retry with exponential backoff

---

## AudioPlaybackService

Plays back recorded audio via AVAudioPlayer:
- Load `audio.m4a` from item directory
- Standard playback controls: play, pause, seek, volume
- `NowPlayingController` updates lock screen info (title, duration, progress)

---

## Watch Integration (RecordingCoordinator)

### iOS ↔ Watch communication
- `iOSWatchSessionManager` manages WCSession
- `RecordingCoordinator` bridges audio state to Watch
- Watch shows recording timer, start/stop controls
- Messages: `startRecording`, `stopRecording`, `recordingStateUpdate`

### Message types (WatchMessageTypes.swift)
```swift
enum WatchMessage: Codable {
    case startRecording
    case stopRecording
    case recordingStateUpdate(isRecording: Bool, elapsed: TimeInterval)
    case transcriptionComplete(itemID: String)
}
```

---

## Error recovery matrix

| Scenario | Detection | Recovery | User Impact |
|---|---|---|---|
| Bluetooth disconnect | Route change notification | Rebuild engine, switch to built-in mic | Brief silence (~200ms) |
| Phone call during recording | Interruption began | Pause recording, save checkpoint | Recording paused |
| Phone call ends | Interruption ended + shouldResume | Resume recording | Continues from pause |
| Disk full during recording | Write failure with NSFileWriteOutOfSpaceError | forceFinish(), alert user | Partial recording saved |
| App terminated mid-recording | Checkpoint manifest on next launch | Recover segments up to last checkpoint | Most content preserved |
| Write buffer overflow | Queue depth > threshold | Drop buffers, log warning | Potential audio gaps |

---

## Performance characteristics

| Metric | Value |
|---|---|
| Sample rate | 44.1 kHz |
| Bit depth | 32-bit float |
| Channels | Mono |
| Buffer interval | ~23ms (1024 samples) |
| WAV size per minute | ~10.6 MB |
| M4A size per minute | ~1.5 MB |
| Max recording duration | Unlimited (disk-space bound) |
| Checkpoint interval | 5 seconds |
| Write retry max | 4 attempts (0.7s total) |
