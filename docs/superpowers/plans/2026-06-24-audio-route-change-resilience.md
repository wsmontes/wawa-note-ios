# Audio Route Change Resilience — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace concurrent-rebuild-with-cancellation pattern with debounce + single rebuild + retry, eliminating session corruption during rapid Bluetooth route changes.

**Architecture:** Single file change in `AudioCaptureService.swift`. Remove `rebuildEngineLightweight`, `rebuildTask?.cancel()`, and the separate `handleEngineConfigChange` path. Add `isRebuilding` flag, `pendingRouteChange` flag, debounce timer with 5s cap, and `performRebuild()` with 3-attempt retry loop.

**Tech Stack:** Swift 6, AVFoundation, Swift Concurrency (`@MainActor`, `Task`, `async/await`)

**Spec:** `docs/superpowers/specs/2026-06-24-audio-route-change-resilience.md`
**JIRA:** [KAN-530](https://wawasoftbc.atlassian.net/browse/KAN-530)

## Global Constraints

- No user interaction during route switches — fully automatic
- Losing seconds of audio during transition is acceptable
- Segment boundaries with device metadata preserved
- `RecordingCoordinator` public API unchanged
- `AudioSessionManager` unchanged
- `forceBuiltInMicRecovery()` and `attemptResume()` public signatures unchanged
- Build must pass, 131 existing tests must not regress

---

### Task 1: Add state properties and refactor handleRouteChange

**Files:**
- Modify: `wawa-note/Audio/AudioCaptureService.swift`

**Interfaces:**
- Produces: `isRebuilding: Bool`, `pendingRouteChange: Bool`, `routeChangeDebounceTask: Task<Void, Never>?`, `routeChangeDebounceStart: Date?`
- Produces: `performRebuild()` async method (called from debounce timer)
- Modifies: `handleRouteChange(_:)` — no longer calls rebuild directly

- [ ] **Step 1: Add new state properties**

At the top of `AudioCaptureService`, add after existing `@Published` properties (near `rebuildTask`):

```swift
// Route change debounce — replaces rebuildTask?.cancel() pattern.
// When multiple route change notifications arrive in rapid succession
// (AirPods emit 3 in <100ms: engineConfigChange + oldDeviceUnavailable +
// newDeviceAvailable), we pause immediately on the first one, then debounce
// subsequent ones and rebuild once after the route settles.
private var isRebuilding = false
private var pendingRouteChange = false
private var routeChangeDebounceTask: Task<Void, Never>?
private var routeChangeDebounceStart: Date?
```

- [ ] **Step 2: Rewrite handleRouteChange to use pause + debounce**

Replace the body of `handleRouteChange(_ n: Notification)` (lines 436-501).

Before replacing, read lines 436-501 to capture the exact current code for reference.

Replace with:

```swift
private func handleRouteChange(_ n: Notification) {
    guard state == .recording || state == .paused else { return }
    // Engine config changes don't carry a RouteChangeReasonKey. Treat them
    // as generic route changes — same debounce + rebuild path applies.
    let reasonValue = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
    let reason = reasonValue.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
    let reasonLabel = reason.map { "\($0.rawValue)" } ?? "engineConfigurationChange"

    AppLog.audio.info("Route change: \(reasonLabel) — input: \(self.sessionManager.currentInputPortName)")

    // Special case: categoryChange is handled separately — another app
    // stole the audio category. If we can't get it back, stop entirely.
    if reason == .categoryChange {
        if self.sessionManager.session.category != .playAndRecord {
            AppLog.audio.warning("Route change: category changed to \(self.sessionManager.session.category.rawValue) — reconfiguring")
            do {
                try self.sessionManager.adaptToRouteChange()
            } catch {
                AppLog.audio.error("Failed to adapt session after category change: \(error.localizedDescription)")
                self.audioInterruptionReason = "Audio category changed by system."
                self.stopRecording()
            }
        }
        return
    }

    // All other route change reasons: pause, debounce, rebuild, resume.
    let wasRecording = state == .recording
    engine?.pause()
    state = .paused
    if wasRecording { stopTimer() }
    audioInterruptionReason = interruptionMessage(for: reason)

    // Debounce: reset timer on each new notification so we rebuild
    // once after the route settles. Cap at 5s to prevent runaway.
    routeChangeDebounceTask?.cancel()
    if routeChangeDebounceStart == nil {
        routeChangeDebounceStart = Date()
    }

    if Date().timeIntervalSince(routeChangeDebounceStart!) > 5.0 {
        AppLog.audio.warning("Route change debounce cap reached — forcing rebuild")
        routeChangeDebounceStart = nil
        performRebuild()
        return
    }

    let delay = sessionManager.settleDelayNs // 750ms BT, 500ms otherwise
    routeChangeDebounceTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: delay)
        guard !Task.isCancelled else { return }
        self?.routeChangeDebounceStart = nil
        await self?.performRebuild()
    }
}

/// Human-readable interruption reason for the UI.
private func interruptionMessage(for reason: AVAudioSession.RouteChangeReason?) -> String {
    guard let reason else { return "Audio engine reconfigured — adapting." }
    switch reason {
    case .newDeviceAvailable:  return "Audio device connected — switching."
    case .oldDeviceUnavailable: return "Audio device disconnected — switching input."
    case .override:             return "Audio route changed — adapting."
    default:                    return "Audio route changed."
    }
}
```

- [ ] **Step 3: Remove the old per-reason switch cases**

The old code (lines 443-500) had individual cases for `.oldDeviceUnavailable`, `.newDeviceAvailable`, `.override`, and `.categoryChange`. The new code handles all non-`.categoryChange` reasons uniformly via debounce.

- [ ] **Step 4: Build and verify compilation**

```bash
make quick
```

Expected: BUILD SUCCEEDED, 131 tests pass.

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Audio/AudioCaptureService.swift
git commit -m "feat: debounce route change notifications with single rebuild

KAN-530: Replace concurrent rebuild cancellation with pause-debounce-rebuild
pattern. Route changes now pause immediately, debounce subsequent
notifications during settle window (750ms BT, 500ms wired, 5s cap), then
rebuild once. Eliminates session corruption from overlapping rebuilds.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Add performRebuild with retry and fallback

**Files:**
- Modify: `wawa-note/Audio/AudioCaptureService.swift`

**Interfaces:**
- Consumes: `isRebuilding`, `pendingRouteChange`, `_rebuildEngineForCurrentRoute(forceBuiltInMic:reason:) -> Bool` (return type changing in Task 3)
- Produces: `performRebuild()` — the single entry point for all rebuild attempts

- [ ] **Step 1: Add performRebuild method**

Insert after `handleRouteChange` (before the `// MARK: - Recovery` section):

```swift
// MARK: - Rebuild orchestration

/// Attempt a rebuild with up to 3 retries. On success, resumes recording.
/// On total failure, vibrates and stays paused with an error message.
private func performRebuild() {
    guard !isRebuilding else {
        // Already rebuilding — flag for retry when current one completes.
        pendingRouteChange = true
        return
    }
    isRebuilding = true

    Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.isRebuilding = false }

        let forceOnAttempt = 2 // 0-indexed: attempt 2 = force built-in mic
        let backoffNs: [UInt64] = [0, 500_000_000, 1_000_000_000]

        for attempt in 0..<3 {
            let forceBuiltIn = attempt >= forceOnAttempt
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: backoffNs[attempt])
            }

            let reason = forceBuiltIn ? "routeChange-forceBuiltIn" : "routeChange"
            let success = await self._rebuildEngineForCurrentRoute(
                forceBuiltInMic: forceBuiltIn, reason: reason
            )

            if success {
                self.state = .recording
                self.startTimer()
                self.audioInterruptionReason = nil
                AppLog.audio.info("performRebuild: succeeded on attempt \(attempt + 1)")

                // If another route change arrived while we were rebuilding,
                // schedule a fresh debounce cycle.
                if self.pendingRouteChange {
                    self.pendingRouteChange = false
                    self.routeChangeDebounceStart = nil
                    let delay = self.sessionManager.settleDelayNs
                    self.routeChangeDebounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled else { return }
                        self?.routeChangeDebounceStart = nil
                        await self?.performRebuild()
                    }
                }
                return
            }

            AppLog.audio.warning("performRebuild: attempt \(attempt + 1) failed")
        }

        // All 3 attempts failed.
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
        self.audioInterruptionReason = "No microphone available"
        AppLog.audio.error("performRebuild: all 3 attempts failed — staying paused")
    }
}
```

- [ ] **Step 2: Build and verify compilation**

```bash
make quick
```

Expected: BUILD SUCCEEDED. May have error about `_rebuildEngineForCurrentRoute` return type — that's fixed in Task 3.

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Audio/AudioCaptureService.swift
git commit -m "feat: add performRebuild with 3-attempt retry and vibrate fallback

KAN-530: Single rebuild entry point. Retries with progressive backoff
(0ms, 500ms, 1s). Forces built-in mic on attempt 3. Vibrates and stays
paused if all attempts fail. Handles pendingRouteChange flag for
notifications that arrive during rebuild.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Modify _rebuildEngineForCurrentRoute to return Bool

**Files:**
- Modify: `wawa-note/Audio/AudioCaptureService.swift`

**Interfaces:**
- Changes: `_rebuildEngineForCurrentRoute(forceBuiltInMic:reason:)` return type from `Void` to `Bool`
- Produces: Returns `true` on successful rebuild, `false` on failure

- [ ] **Step 1: Change the method signature**

In `_rebuildEngineForCurrentRoute` (line 540), change:

```swift
// BEFORE:
@MainActor
private func _rebuildEngineForCurrentRoute(forceBuiltInMic: Bool, reason: String) async {

// AFTER:
@MainActor
private func _rebuildEngineForCurrentRoute(forceBuiltInMic: Bool, reason: String) async -> Bool {
```

- [ ] **Step 2: Replace stopRecording() calls with return false**

Find every `stopRecording()` call inside `_rebuildEngineForCurrentRoute` and replace with `return false`.

Current locations (approximate — exact lines may shift from prior edits):
- Line 548: `guard let meetingId...` block → `stopRecording()` → change to `return false`
- Line 577: session reconfigure failed → `stopRecording()` → change to `return false`
- Line 603: audio format creation failed → `stopRecording()` → change to `return false`
- Line 612: new segment open failed → `stopRecording()` → change to `return false`
- Line 637: engine nil after build → `stopRecording()` → change to `return false`

Also fix line 542-544 guard (unexpected state): change from `return` to `return false`.

And line 594 `guard buildAndStartEngine(reason: reason) else { return }` → change to `guard buildAndStartEngine(reason: reason) else { return false }`.

- [ ] **Step 3: Add return true at the end**

After line 641 (`AppLog.event("audio", "rebuildEngine(...)")`), add:

```swift
return true
```

- [ ] **Step 4: Update the rebuildEngineForCurrentRoute wrapper**

The public wrapper `rebuildEngineForCurrentRoute` (line 528) wraps the internal method. Update it to handle the new return type:

```swift
// BEFORE:
private func rebuildEngineForCurrentRoute(forceBuiltInMic: Bool, reason: String) async {
    rebuildTask?.cancel()
    rebuildTask = Task { @MainActor [weak self] in
        await self?._rebuildEngineForCurrentRoute(forceBuiltInMic: forceBuiltInMic, reason: reason)
    }
    await rebuildTask?.value
}

// AFTER (keep wrapper for forceBuiltInMicRecovery and mediaServicesReset):
private func rebuildEngineForCurrentRoute(forceBuiltInMic: Bool, reason: String) async -> Bool {
    // Direct call — no more cancellation. performRebuild handles retry.
    await _rebuildEngineForCurrentRoute(forceBuiltInMic: forceBuiltInMic, reason: reason)
}
```

- [ ] **Step 5: Update callers of rebuildEngineForCurrentRoute**

- `forceBuiltInMicRecovery()` (line 518): change `await rebuildEngineForCurrentRoute(...)` to `_ = await rebuildEngineForCurrentRoute(...)`
- `mediaServicesWereReset` handler (line 361): same change
- `attemptResume` (line 753): same change

- [ ] **Step 6: Remove rebuildTask property**

Delete the `rebuildTask` property declaration. It's no longer used.

Search for: `private var rebuildTask: Task<Void, Never>?` and remove it.

- [ ] **Step 7: Build and verify compilation**

```bash
make quick
```

Expected: BUILD SUCCEEDED, 131 tests pass.

- [ ] **Step 8: Commit**

```bash
git add wawa-note/Audio/AudioCaptureService.swift
git commit -m "feat: make _rebuildEngineForCurrentRoute return success/failure

KAN-530: Method now returns Bool instead of calling stopRecording()
internally. Caller (performRebuild) decides state transitions. Removes
rebuildTask cancellation pattern.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Remove rebuildEngineLightweight and handleEngineConfigChange

**Files:**
- Modify: `wawa-note/Audio/AudioCaptureService.swift`

**Interfaces:**
- Removes: `rebuildEngineLightweight(reason:)`, `_rebuildEngineLightweight(reason:)`, `handleEngineConfigChange(_:)`
- Engine config changes now flow through the same debounce path as route changes

- [ ] **Step 1: Point engine config change observer to handleRouteChange**

In `observeNotifications()` (line 374), change the engine config observer:

```swift
// BEFORE:
if let eng = engine {
    observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng, queue: q) { [weak self] n in self?.handleEngineConfigChange(n) })
}

// AFTER:
if let eng = engine {
    observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng, queue: q) { [weak self] n in
        // Engine config changes don't carry AVAudioSessionRouteChangeReasonKey.
        // handleRouteChange handles this — the guard uses optional binding and
        // falls through to generic debounce path with nil reason.
        AppLog.audio.info("Engine config change — routing through unified debounce path")
        self?.handleRouteChange(n)
    })
}
```

Note: The `handleRouteChange` method in Task 1 already handles the missing-reason-key case (see the guard fallback in Step 2). When an engine config change arrives without `AVAudioSessionRouteChangeReasonKey`, the guard fails through to the generic debounce path with message "Audio route changed."
```

- [ ] **Step 2: Remove handleEngineConfigChange method**

Delete lines 503-512 (the `handleEngineConfigChange` method).

- [ ] **Step 3: Remove rebuildEngineLightweight and _rebuildEngineLightweight**

Delete lines 648-695 (both `rebuildEngineLightweight` and `_rebuildEngineLightweight` methods).

Also check `reRegisterEngineObserver` — it re-registers the engine config observer. Make sure the new observer registration (from Step 1) uses the same pattern. It already does — `reRegisterEngineObserver` calls the same `observeNotifications()` logic that we updated in Step 1.

- [ ] **Step 4: Build and verify**

```bash
make quick
```

Expected: BUILD SUCCEEDED, 131 tests pass.

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Audio/AudioCaptureService.swift
git commit -m "feat: remove lightweight rebuild, unify via debounce path

KAN-530: Engine config changes now flow through the same pause-debounce-
rebuild path as route changes. Removes rebuildEngineLightweight which
competed with full rebuilds for the same rebuildTask.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Final verification and deploy

- [ ] **Step 1: Full build and test**

```bash
make quick
```

Expected: BUILD SUCCEEDED, 131 tests pass.

- [ ] **Step 2: Deploy to device**

```bash
make deploy
```

Expected: BUILD SUCCEEDED, App installed on iPhone 14 Plus.

- [ ] **Step 3: Manual test scenarios**

On device:
1. Start recording → connect AirPods → verify recording continues on AirPods (segment created)
2. Recording with AirPods → disconnect AirPods → verify recording continues on iPhone mic (segment created)
3. Recording with AirPods → put AirPods in case → verify brief pause → auto-resume on iPhone mic
4. Recording → connect Bluetooth speaker without mic → verify stays on iPhone mic

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: final verification — audio route change resilience

KAN-530: All 131 tests pass. Ready for device testing.

Co-Authored-By: Claude <noreply@anthropic.com>"
```
