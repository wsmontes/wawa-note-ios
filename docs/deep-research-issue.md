# KAN-XXX: Deep Research — Audio Route Changes + SwiftData Cross-Context Observation

**Epic:** KAN-518 (MVP V1)
**Type:** Task | **Priority:** High
**Labels:** deep-research, audio, swiftdata, recording-stability

---

## Scope

This issue consolidates findings from adversarial deep research (103 agents, 1,532 tool calls, 3.8M tokens) covering two interconnected technical domains critical to the Wawa Note MVP:

1. **Audio route change resilience** — how to handle Bluetooth/AirPods connect/disconnect during recording
2. **SwiftData cross-context observation** — how detail views observe status changes made by background processing pipelines

---

## Part 1: Audio Route Change Resilience

### Current State in Wawa Note

The `AudioCaptureService._rebuildEngineForCurrentRoute()` tears down AVAudioEngine, reconfigures the audio session, and builds a new engine on route change. It has three structural flaws:

**Bug 1 — Cancelamento quebrado (root cause)**
`rebuildTask?.cancel()` at `AudioCaptureService.swift:532` cancels the previous rebuild when a new route change notification arrives. But the previous rebuild has already torn down the engine (`removeTap → stop → reset → engine=nil`, lines 562-566). When AirPods emit 3 rapid notifications (`engineConfigChange + oldDeviceUnavailable + newDeviceAvailable` in <100ms), three rebuilds start and cancel each other mid-teardown, leaving the session corrupted.

**Bug 2 — Zombie state on engine start failure**
Line 594: `guard buildAndStartEngine(reason: reason) else { return }` — if the new engine fails to start, the method returns WITHOUT setting `state = .paused`. The state remains `.recording` but `engine = nil`. No audio captured; user believes recording continues.

**Bug 3 — Lightweight competes with full rebuild**
`rebuildEngineLightweight` (line 650) also calls `rebuildTask?.cancel()`, cancelling full rebuilds mid-execution. The lightweight doesn't deactivate the session (to preserve Bluetooth SCO link), but the full rebuild does. They compete for the same `rebuildTask`.

### What Apple Recommends

Per [official documentation](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes):

> "When you receive a route change notification, update your app's UI and **pause any audio recording** or playback, then re-configure the audio session for the new route."

> "**Always pause on `.oldDeviceUnavailable`**, reconfigure the session for the current route, and only resume/restart recording after the session is re-established."

Wawa Note currently does NOT pause on `.oldDeviceUnavailable` when another input is available — it silently switches inputs, which Apple explicitly warns against.

### Proposed Design

**Principle:** Pause → Debounce → Single Rebuild → Resume. Never cancel a rebuild in progress.

```
Route change notification → PAUSE → DEBOUNCE (1s BT, 500ms wired) → SINGLE REBUILD
  → success? → RESUME
  → fail? → STAY PAUSED + offer "Force iPhone Mic"
```

**Key changes:**
- Remove `rebuildTask?.cancel()` pattern
- Add `isRebuilding` flag — ignore notifications during rebuild, set `pendingRouteChange = true`
- Add debounce timer — resets on each new notification, executes once after route settles
- Always pause before rebuild on `.oldDeviceUnavailable`
- Remove `rebuildEngineLightweight` — fold into unified path
- Preserve existing `AudioSessionManager` device detection (`isBluetoothInvolved`, `settleDelayNs`, `bestAvailableInput`, `fallbackInput`)

**Device compatibility:** AirPods HFP, non-Apple Bluetooth headsets, CarPlay, wired headsets, USB mics. Rebuild path identical for all; only debounce timing varies.

---

## Part 2: SwiftData Cross-Context Observation

### Deep Research Findings

Adversarial verification of 25 claims with 3-voter panels. **9 confirmed, 16 refuted.**

**✅ 3-0 CONFIRMED:**

| Claim | Implication |
|-------|-------------|
| SwiftData model objects are tied to the ModelContext that fetched them | `let item` from main context not updated by pipeline's separate context |
| @Model = @Observable only within the same context | `@Query` works for lists; detail view direct refs don't cross contexts |
| Apple's Backyard Birds never handles cross-context observation | Apple's own sample doesn't address this problem |
| Ramble-ios avoids SwiftData entirely for the record-to-ready data path | Codable structs + JSON + NotificationCenter — reliable, no SwiftData bugs |

**❌ 0-3 REFUTED (proven false):**

| Claim | Evidence |
|-------|----------|
| "@Query detects changes from any ModelContext" | **BUGS iOS 17-26** — Apple engineers acknowledge (FB12689036, FB14240514, FB14750050, FB15281260) |
| "System automatically merges background context changes" | Apple DTS engineer confirms it's "supposed to" but doesn't work reliably |
| "@Query + background ModelActor = automatic UI update" | 4 unresolved bugs across iOS 17-26 |
| "context.refresh() is the recommended API for stale objects" | No Apple documentation supports this claim |

### Reliable Cross-Context Tools (iOS 18+)

- **`ModelContext.didSave`** — provides `Set<PersistentIdentifier>` (Sendable, thread-safe). Was completely non-functional on iOS 17.x (FB12319007, FB13509149). **Works on iOS 18+.**
- **History API** (WWDC24) — pull-based, requires `DefaultHistoryToken` persistence in UserDefaults, tokens can expire.

### Recommendation

`@Query` for normal UI binding + `ModelContext.didSave` observer as safety net filtering by `PersistentIdentifier`:

```swift
.onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { n in
    guard let updatedIds = n.userInfo?[ModelContext.NotificationKey.updatedIdentifiers]
            as? Set<PersistentIdentifier>,
          updatedIds.contains(where: { $0.description.contains(itemID.uuidString) })
    else { return }
    refreshID = UUID() // force @Query re-evaluation
}
```

---

## Sources

- [Apple: Responding to Audio Route Changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
- [WWDC 2023 Session 10154: Build an app with SwiftData](https://developer.apple.com/videos/play/wwdc2023/10154/)
- [WWDC 2023 Session 10196: Model your schema with SwiftData](https://developer.apple.com/videos/play/wwdc2023/10196/)
- [WWDC 2024 Session 10075: Track model changes with SwiftData history](https://developer.apple.com/videos/play/wwdc2024/10075/)
- [WWDC 2024 Session 10137: What's new in SwiftData](https://developer.apple.com/videos/play/wwdc2024/10137/)
- [Apple Sample: Backyard Birds](https://github.com/apple/sample-backyard-birds)
- [Apple Dev Forums thread 763500: ModelContext and cross-context observation](https://developer.apple.com/forums/thread/763500)
- [Hacking with Swift: SwiftData Concurrency](https://www.hackingwithswift.com/quick-start/swiftdata/how-swiftdata-works-with-swift-concurrency)
- [Ramble-ios: Open-source recording app without SwiftData](https://github.com/Jpoliachik/ramble-ios)
- [Say It Right PR #109: AudioSessionManager](https://github.com/mmattern76/say-it-right/pull/109)
- [HaishinKit Issue #1732: Route change audio gaps](https://github.com/HaishinKit/HaishinKit.swift/issues/1732)
- [Stack Overflow: Route change handling pattern](https://stackoverflow.com/questions/74300580/how-to-stop-audio-playback-when-disconnecting-audio-devices-in-swift-app)
