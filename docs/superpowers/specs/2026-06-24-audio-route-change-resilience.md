# Audio Route Change Resilience

**Date:** 2026-06-24
**Status:** Approved
**JIRA:** [KAN-530](https://wawasoftbc.atlassian.net/browse/KAN-530)
**Epic:** KAN-518 (MVP V1)

## Problem

`AudioCaptureService._rebuildEngineForCurrentRoute()` has three structural bugs that cause recording corruption when Bluetooth devices (AirPods, headsets) connect/disconnect during recording:

1. **Cancelamento quebrado** — `rebuildTask?.cancel()` (line 532) cancels the previous rebuild, but the previous rebuild has already torn down the engine. When AirPods emit 3 rapid notifications in <100ms, three rebuilds start and cancel each other mid-teardown.

2. **Zombie state** — Line 594: `guard buildAndStartEngine(...) else { return }` exits without setting `state = .paused`, leaving `state = .recording` with `engine = nil`.

3. **Lightweight competition** — `rebuildEngineLightweight` and full rebuild compete for the same `rebuildTask`, creating inconsistent session state.

## Design

### Principle

**Debounce + Single Rebuild.** Pause on first notification, accumulate subsequent ones during a settle window, rebuild once, resume. Never cancel a rebuild in progress.

### State Flow

```
STABLE (.recording)
    │
    │ route change notification
    ▼
PAUSE (.paused)
    │ engine?.pause(), stopTimer()
    │ audioInterruptionReason = message
    │ start/reset debounce timer (1s BT, 500ms wired, cap 5s)
    │
    ├── new notification arrives during debounce
    │   └── reset timer
    │
    ▼ debounce expires
REBUILD
    │ isRebuilding = true
    │ checkpoint segment → teardown engine → deactivate session
    │ → configure session → build engine → open new segment
    │ → re-register observers
    │
    ├── SUCCESS → .recording, startTimer(), clear interruption reason
    │   └── if pendingRouteChange → schedule new debounce
    │
    └── FAILURE
        ├── retry 1: backoff 500ms, rebuild again
        │   └── FAILURE
        ├── retry 2: forceBuiltInMic, backoff 1s, rebuild
        │   └── FAILURE
        └── VIBRATE + stay .paused + "No microphone available"
```

### API Changes in AudioCaptureService

**Removed:**
- `rebuildEngineLightweight()` — folded into unified debounce path
- `rebuildTask?.cancel()` pattern — replaced by `isRebuilding` flag
- `handleEngineConfigChange()` as separate handler — same debounce flow

**Added:**
- `isRebuilding: Bool` — blocks concurrent rebuilds
- `pendingRouteChange: Bool` — retry flag after rebuild completes
- `routeChangeDebounceTask: Task<Void, Never>?` — cancellable timer
- `routeChangeDebounceStart: Date?` — 5s cap on debounce accumulation
- `performRebuild()` — unified rebuild with retry loop and fallback

**Modified:**
- `_rebuildEngineForCurrentRoute()` now returns `Bool` instead of calling `stopRecording()` internally. Caller decides state transitions.
- `handleRouteChange()` no longer calls rebuild directly. Instead: pause → start/reset debounce timer.

### Behavior by Scenario

| Scenario | Behavior |
|----------|----------|
| AirPods disconnect (mic available) | Pause → wait 1s → rebuild on built-in mic → resume |
| AirPods connect mid-recording | Pause → wait 1s → rebuild on AirPods → resume |
| Rapid disconnect+reconnect (device switching) | Pause → debounce absorbs 3 notifications → 1 rebuild → resume |
| Wired headset unplug | Pause → wait 500ms → rebuild on built-in mic → resume |
| CarPlay disconnect | Pause → wait 750ms → rebuild → resume |
| Bluetooth speaker without mic connects | `isBluetoothWithoutMic` detected → skip, use `fallbackInput` |
| Rebuild fails 3 times | Vibrate → stay .paused → "No microphone available" |
| Notification arrives during rebuild | `isRebuilding` blocks → `pendingRouteChange = true` → processed after rebuild |
| Notifications keep arriving (runaway) | 5s cap on debounce → force rebuild regardless |
| Phone call interruption | Existing `handleInterruption` — unchanged |
| Media services reset | Existing handler — force built-in mic — unchanged |

### Preserved

- Segment creation with metadata (`inputPortName`, `routeChangeReason`, `sampleRate`) on each route change
- `AudioSessionManager` device detection logic (`isBluetoothInvolved`, `settleDelayNs`, `bestAvailableInput`, `fallbackInput`)
- `forceBuiltInMicRecovery()` public API
- `attemptResume()` public API
- Crash checkpoint recovery
- NotificationCenter observers for route, interruption, media reset, engine config change

## Constraints

- **No user interaction** — all switching is automatic. User only acts on failure (vibrate + pause).
- **Audio gap acceptable** — losing seconds of audio during transition is expected and acceptable.
- **Traceability preserved** — segment boundaries with device metadata remain for diagnostics.
- **Backward compatible** — `RecordingCoordinator` public API unchanged.

## References

- [Apple: Responding to Audio Route Changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
- [KAN-530: Deep Research findings](https://wawasoftbc.atlassian.net/browse/KAN-530)
- `AudioCaptureService.swift` — current rebuild implementation
- `AudioSessionManager.swift` — device detection and ranking
