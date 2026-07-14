# Transcription Pipeline Hardening — Code Review Fixes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 15 bugs in the transcription pipeline found by max-effort code review — 7 critical (crash/data-loss) + 8 high (silent corruption/reliability), with focus on long audio (1h+) and re-transcription paths.

**Architecture:** Fixes span 3 phases: (1) crash/memory fixes in the hot path, (2) data integrity across the capture→transcribe→merge chain, (3) protocol hardening + re-transcription lifecycle. Each phase produces independently testable improvements. Existing patterns (protocol-first, `async/await`, `@MainActor` view models, typed errors) are preserved.

**Tech Stack:** Swift 5.10+, Swift Concurrency, AVFoundation, Speech, SwiftData, WawaNoteCore

## Global Constraints

- Target device: iPhone 14 Plus (iOS 18.6.2)
- No hardcoded API keys, provider URLs, or secrets
- Keep SwiftUI views thin — business logic in services
- Use `AIConfigService.shared.requestParams(for:model:)` for AI requests
- Protocol-first boundaries (`TranscriptionEngine`, `AIProvider`, etc.)
- All file changes must be added to `wawa-note.xcodeproj/project.pbxproj` (via Xcode)
- Swift Concurrency (`async/await`) for async flows, `@MainActor` for UI view models
- Use Keychain for API keys, FileManager for large artifacts, SwiftData for metadata
- Commit messages must follow format: `KAN-XX: description`
- Each commit = one logical change with passing tests

---

### Task 1: Fix Double-Resume Crash in Cloud Fallback Continuation

**Files:**
- Modify: `wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift:426-554`

**Interfaces:**
- Consumes: `SFSpeechRecognizer.recognitionTask(with:resultHandler:)`, `withCheckedThrowingContinuation`
- Produces: Thread-safe continuation resume via `OSAtomicCompareAndSwap`-guarded `hasResumed`

**Background:** `hasResumed` (Bool) is read/written from 3 threads: SFSpeechRecognizer callback (Speech internal queue), timeout DispatchWorkItem (main queue), and cloud fallback path with separate `cloudHasResumed`. Plain Bool lacks memory barriers — all 3 can pass the `!hasResumed` guard before any sets it to true, causing **double-resume trap crash** (`withCheckedThrowingContinuation`).

- [ ] **Step 1: Replace `hasResumed` Bool with `os_unfair_lock`-guarded state**

Replace the local `var hasResumed = false` at line 426 with a lock-protected helper:

```swift
// REPLACE line 426:
// var hasResumed = false

// WITH:
let continuationLock = os_unfair_lock_t.allocate(capacity: 1)
continuationLock.initialize(to: os_unfair_lock())
var hasResumed = false

func tryResume(_ block: @escaping () -> Void) -> Bool {
    os_unfair_lock_lock(continuationLock)
    defer { os_unfair_lock_unlock(continuationLock) }
    guard !hasResumed else { return false }
    hasResumed = true
    return true
}
```

- [ ] **Step 2: Guard every `continuation.resume()` call behind `tryResume`**

Replace all 4 resume sites in `transcribeDirect`:

```swift
// TIMEOUT — replace lines 444-451:
let timeoutWorkItem = DispatchWorkItem {
    guard tryResume({
        recognitionTask?.cancel()
        continuation.resume(
            throwing: TranscriptionError.recognitionFailed(
                "Recognition timed out after \(Int(timeout))s"))
    }) else { return }
}

// ON-DEVICE ERROR — replace lines 456-509:
if let error {
    timeoutWorkItem.cancel()
    let nsError = error as NSError
    // ... logging ...

    if nsError.domain.contains("AssistantError") && forceOnDevice {
        guard tryResume({
            // cloud fallback path
            let cloudRequest = SFSpeechURLRecognitionRequest(url: recognitionURL)
            // ... (existing cloud fallback code stays the same) ...
        }) else { return }
        return
    }

    guard tryResume({
        continuation.resume(
            throwing: TranscriptionError.recognitionFailed(
                "\(nsError.domain)/\(nsError.code): \(error.localizedDescription)"))
    }) else { return }
    return
}

// FINAL RESULT — replace lines 539-553:
guard result.isFinal else { return }
accumulatedSegments.append(contentsOf: result.bestTranscription.segments)

guard tryResume({
    let transcript = self.buildTranscript(
        from: accumulatedSegments, recognizer: recognizer, meetingId: meetingId)
    continuation.resume(returning: transcript)
}) else { return }
```

- [ ] **Step 3: Remove `cloudHasResumed` — single lock covers both paths**

Delete the separate `var cloudHasResumed = false` at line 476. The `tryResume` function above already prevents double-resume from **any** path (timeout, on-device error, cloud fallback success, cloud fallback error). Replace `cloudHasResumed` guards with the same `tryResume` pattern:

```swift
// REPLACE lines 476-501 (cloud fallback closure):
var cloudHasResumed = false  // DELETE THIS LINE
let cloudTask = recognizer.recognitionTask(with: cloudRequest) {
    cloudResult, cloudError in
    // REPLACE: guard !cloudHasResumed else { return }
    if let cloudError {
        guard tryResume({
            let cloudNSError = cloudError as NSError
            continuation.resume(
                throwing: TranscriptionError.recognitionFailed(
                    "\(cloudNSError.domain)/\(cloudNSError.code): \(cloudError.localizedDescription)"))
        }) else { return }
        return
    }
    guard let cloudResult = cloudResult, cloudResult.isFinal else { return }
    guard tryResume({
        self.usedCloudFallback = true
        let transcript = self.buildTranscript(
            from: cloudResult, recognizer: recognizer, meetingId: meetingId)
        continuation.resume(returning: transcript)
    }) else { return }
}
```

- [ ] **Step 4: Add `defer` to clean up lock allocation**

At the end of the `withCheckedThrowingContinuation` block, ensure the lock is deallocated:

```swift
defer {
    continuationLock.deinitialize(count: 1)
    continuationLock.deallocate()
}
```

- [ ] **Step 5: Build and run unit tests**

```bash
make quick
```

Expected: Build passes. Existing tests pass. No `BUG IN CLIENT OF LIBDISPATCH` or double-resume traps.

- [ ] **Step 6: Commit**

```bash
git add wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift
git commit -m "fix: prevent double-resume crash in cloud fallback continuation

Replace plain Bool hasResumed/cloudHasResumed with os_unfair_lock-guarded
tryResume() helper. Three threads (SFSpeechRecognizer callback, timeout
DispatchWorkItem, cloud fallback) could all pass the guard before any set
hasResumed=true, causing withCheckedThrowingContinuation double-resume trap.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Fix `prepareForRecognition` Memory — Stream AAC→PCM Instead of Single Buffer

**Files:**
- Modify: `wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift:656-731`

**Interfaces:**
- Consumes: `AVAudioFile`, `AVAudioConverter`, `AVAudioPCMBuffer`
- Produces: `prepareForRecognition(_:) -> URL` — same signature, streaming implementation

**Background:** `prepareForRecognition` loads the **entire** AAC file into a single `AVAudioPCMBuffer` via `inputFile.read(into:)`. For 1h at 44.1kHz mono Float32: 44,100 × 3,600 × 4 = ~635 MB contiguous allocation. Adding the output buffer at 16kHz Int16 (~230 MB), total is ~865 MB — exceeds the iPhone 14 Plus jetsam limit (~1.2-1.8 GB for foreground media app). iOS kills the process with `EXC_RESOURCE`.

- [ ] **Step 1: Replace single-buffer read with segmented conversion**

Replace the entire method body after the format setup (lines 691-731):

```swift
// REPLACE lines 691-731 (from "Read the entire input file..." comment through end of method):

// Read and convert in segments to avoid loading the entire file into RAM.
// A 1-hour AAC file decoded to 16kHz mono Int16 is ~115 MB — manageable
// as a single output, but the intermediate Float32 buffer at the source
// sample rate can be 4-8x larger. Process in 30-second segments.
let segmentDuration: AVAudioFramePosition = AVAudioFramePosition(inputFormat.sampleRate * 30)
inputFile.framePosition = 0

var totalOutputFrames: AVAudioFrameCount = 0
var outputBuffers: [AVAudioPCMBuffer] = []

while inputFile.framePosition < inputFile.length {
    let remaining = inputFile.length - inputFile.framePosition
    let framesToRead = AVAudioFrameCount(min(segmentDuration, remaining))

    guard let inputBuf = AVAudioPCMBuffer(
        pcmFormat: inputFormat, frameCapacity: framesToRead) else {
        throw TranscriptionError.recognitionFailed("Cannot allocate input buffer")
    }
    try inputFile.read(into: inputBuf)

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(inputBuf.frameLength) * ratio)
    guard let outputBuf = AVAudioPCMBuffer(
        pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
        throw TranscriptionError.recognitionFailed("Cannot allocate output buffer")
    }

    var provided = false
    var convertError: NSError?
    let status = converter.convert(to: outputBuf, error: &convertError) { _, outStatus in
        if !provided {
            provided = true
            outStatus.pointee = .haveData
            return inputBuf
        }
        outStatus.pointee = .noDataNow
        return nil
    }

    if let convertError { throw convertError }
    guard outputBuf.frameLength > 0 else {
        throw TranscriptionError.recognitionFailed("Decode segment produced empty output")
    }

    outputBuffers.append(outputBuf)
    totalOutputFrames += outputBuf.frameLength
}

guard totalOutputFrames > 0 else {
    throw TranscriptionError.recognitionFailed("Decode produced empty output")
}

// Write all converted segments to a single output file
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("pcm_\(UUID().uuidString).wav")
let outputFile = try AVAudioFile(
    forWriting: tempURL, settings: outputFormat.settings,
    commonFormat: .pcmFormatInt16, interleaved: false)

for buffer in outputBuffers {
    try outputFile.write(from: buffer)
}

AppLog.transcription.info(
    "PCM decode complete: \(totalOutputFrames) frames @ \(Int(outputFormat.sampleRate))Hz → \(tempURL.lastPathComponent)"
)
return tempURL
```

- [ ] **Step 2: Build and verify**

```bash
make quick
```

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift
git commit -m "fix: stream AAC-to-PCM decode in 30s segments to prevent jetsam

Replace single AVAudioPCMBuffer read of entire file with segmented conversion.
A 1-hour AAC file at 44.1kHz produces a 635 MB Float32 input buffer + 230 MB
Int16 output buffer — 865 MB contiguous, exceeding iPhone 14 Plus jetsam limit.
Segmenting at 30s caps per-segment allocation at ~5 MB.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Fix Audio Real-Time Thread Violations — Remove Heap Allocation + Lock from Tap Callback

**Files:**
- Modify: `wawa-note/Audio/AudioCaptureService.swift:144-157,253-293`

**Interfaces:**
- Consumes: `AVAudioEngine.installTap(onBus:bufferSize:format:block:)`, `vDSP_maxmgv`, `NSLock`
- Produces: Lock-free ring buffer for audio level, `DispatchQueue` for level processing off the audio thread

**Background:** The audio tap callback (real-time I/O thread) does `Array(UnsafeBufferPointer)` → `malloc`, `vDSP_maxmgv`, adaptive gain math, `NSLock.lock()`. Both heap allocation and lock acquisition are **forbidden** on the real-time audio thread — they cause priority inversion, buffer underruns, and potential audio session invalidation. The samples are already being copied for the file writer; the level calculation can use an atomic variable instead of a lock.

- [ ] **Step 1: Replace `Array` copy + `NSLock` with atomic ring buffer for audio level**

Replace the audio tap callback (lines 144-157) and `updateAudioLevel` (lines 253-293):

```swift
// REPLACE lines 144-157 (tap callback):
inputNode.installTap(onBus: 0, bufferSize: Self.captureBufferSize, format: nil) {
    [weak self] buffer, _ in
    guard let self else { return }

    // Level: atomic peak update only — no heap allocation, no locks.
    // vDSP_maxmgv operates on the buffer's floatChannelData directly
    // (no copy). The atomic store is lock-free on ARM64.
    if let ch = buffer.floatChannelData {
        var peak: Float = 0
        vDSP_maxmgv(ch[0], 1, &peak, vDSP_Length(buffer.frameLength))
        let normalized = min(1.0, peak * self._adaptiveGain)
        // Atomic store — non-locking on ARM64
        os_atomic_store(&self._atomicLevel, normalized, .relaxed)
    }

    // Write samples: Array copy is still required (Core Audio reuses tap
    // buffer memory). This is a fast memcpy and the only safe way to retain
    // PCM data for async writing.
    guard let ch = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
    self.fileWriter.write(samples: samples, frameLength: n, format: buffer.format)
}
```

- [ ] **Step 2: Replace `NSLock` + `rawLevel` with atomic variable**

```swift
// REPLACE lines 70-71:
// private let levelLock = NSLock()
// private var rawLevel: Float = 0

// WITH:
/// Atomic audio level — written from real-time audio thread (lock-free ARM64 store),
/// read from MainActor level-smoothing Task.
private var _atomicLevel: os_atomic_int32_t = .init(0)
/// Adaptive gain, updated from the level-smoothing Task (not the audio thread).
/// Read atomically in the tap callback.
private var _adaptiveGain: Float = 4.0
```

- [ ] **Step 3: Move adaptive gain + silence detection off the audio thread**

Remove adaptive gain and silence tracking from `updateAudioLevel` (delete lines 253-281). Move them into `startLevelSmoothing`:

```swift
// REPLACE startLevelSmoothing (lines 295-308):
private func startLevelSmoothing() {
    levelSmoothTask?.cancel()
    levelSmoothTask = Task { @MainActor [weak self] in
        var silenceSeconds: Double = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 66_000_000)  // ~15 Hz
            guard let self else { return }

            // Read atomic level (lock-free)
            let rawBits = os_atomic_load(&self._atomicLevel, .relaxed)
            let raw = Float(bitPattern: UInt32(bitPattern: Int32(rawBits)))
            self.audioLevel = raw

            // Adaptive gain — on MainActor, safe to do math
            if raw > 0.01 && raw < 1.0 {
                if raw > 0.85 {
                    self._adaptiveGain = max(1.0, self._adaptiveGain * 0.98)
                } else if raw < 0.25 && raw > 0.001 {
                    self._adaptiveGain = min(8.0, self._adaptiveGain * 1.02)
                }
            }

            // Silence detection
            if raw < 0.015 {
                silenceSeconds += 0.066
            } else {
                if silenceSeconds >= 60 {
                    AppLog.audio.info("Silence ended after \(Int(silenceSeconds))s")
                }
                silenceSeconds = 0
            }
            let isSilent = silenceSeconds >= 60
            if self.silenceDetected != isSilent {
                self.silenceDetected = isSilent
            }
        }
    }
}
```

- [ ] **Step 4: Remove `updateAudioLevel` method entirely**

Delete the `updateAudioLevel(from:)` method (lines 253-293) and the `levelLock`/`rawLevel`/`adaptiveGain`/`silenceConsecutiveSeconds` declarations (lines 70-71, 249-251). These are now handled inline or in the smoothing Task.

- [ ] **Step 5: Add import for atomic operations**

At the top of the file with other imports:
```swift
import os  // for os_atomic_store / os_atomic_load
```

- [ ] **Step 6: Build and test**

```bash
make quick
```

- [ ] **Step 7: Commit**

```bash
git add wawa-note/Audio/AudioCaptureService.swift
git commit -m "fix: remove heap allocation and NSLock from audio real-time thread

Move vDSP_maxmgv to operate directly on floatChannelData (no Array copy for
level), replace NSLock+rawLevel with lock-free os_atomic_store/load, and move
adaptive gain + silence detection off the audio I/O thread into the MainActor
level-smoothing Task. Heap allocation and lock acquisition on the real-time
audio thread cause priority inversion, buffer underruns, and potential
AVAudioSession invalidation.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Fix Engine Rebuild Race Condition — Serialize Full + Lightweight Rebuilds

**Files:**
- Modify: `wawa-note/Audio/AudioCaptureService.swift:546-712`

**Interfaces:**
- Consumes: `rebuildTask: Task<Void, Never>?`, `_rebuildEngineForCurrentRoute`, `_rebuildEngineLightweight`
- Produces: Single serial `rebuildTask` actor-gated by `withTaskCancellationHandler`

**Background:** Bluetooth HFP handoff triggers both `routeChangeNotification` and `AVAudioEngineConfigurationChange` in rapid succession. `rebuildEngineForCurrentRoute` and `rebuildEngineLightweight` each cancel the other's `rebuildTask` and start a new one. But `Task.cancel()` is cooperative — both continue executing past the cancellation point. Both tear down the engine, both build new engines, and the first one's `self.engine` is overwritten by the second → tap from second rebuild points to a dead engine, recording silence.

- [ ] **Step 1: Replace `rebuildTask?.cancel()` pattern with actor-gated serial execution**

Replace the `rebuildEngineForCurrentRoute` method (lines 546-555) with:

```swift
private func rebuildEngineForCurrentRoute(forceBuiltInMic: Bool, reason: String) async {
    // Serialize ALL rebuilds through a single unstructured Task tree.
    // Cancelling the previous Task is insufficient — Task.cancel() is
    // cooperative, and both the old and new rebuild can execute concurrently.
    // Instead, wait for any in-progress rebuild to complete naturally,
    // then start the new one. This guarantees at most one engine rebuild
    // executes at any time.
    if let existing = rebuildTask {
        await existing.value  // Wait for completion, don't cancel
    }
    rebuildTask = Task { [weak self] in
        await self?._rebuildEngineForCurrentRoute(
            forceBuiltInMic: forceBuiltInMic, reason: reason)
    }
    await rebuildTask?.value
}
```

- [ ] **Step 2: Apply same pattern to `rebuildEngineLightweight`**

Replace lines 673-680:

```swift
private func rebuildEngineLightweight(reason: String) async {
    if let existing = rebuildTask {
        await existing.value  // Wait, don't cancel
    }
    rebuildTask = Task { [weak self] in
        await self?._rebuildEngineLightweight(reason: reason)
    }
    await rebuildTask?.value
}
```

- [ ] **Step 3: Add state check at start of each rebuild implementation**

Both `_rebuildEngineForCurrentRoute` and `_rebuildEngineLightweight` already check `state == .recording || state == .paused`. Add an additional guard at the top of each:

```swift
// ADD at start of _rebuildEngineForCurrentRoute (after existing guard, ~line 559):
guard rebuildTask?.isCancelled != true else {
    AppLog.audio.warning("rebuildEngine(\(reason)): cancelled before start")
    return
}
```

- [ ] **Step 4: Build and test**

```bash
make quick
```

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Audio/AudioCaptureService.swift
git commit -m "fix: serialize engine rebuilds by awaiting instead of cancelling

Replace rebuildTask?.cancel() with await rebuildTask?.value in both
rebuildEngineForCurrentRoute and rebuildEngineLightweight. Task.cancel()
is cooperative — Bluetooth HFP handoff triggers routeChangeNotification
and AVAudioEngineConfigurationChange simultaneously, both rebuilds execute
concurrently, and the first's self.engine is overwritten by the second,
losing the audio tap and recording silence.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Add `onCheckpoint`, `onProgress`, `resumeFromChunk`, and `finalize()` to `TranscriptionEngine` Protocol

**Files:**
- Modify: `wawa-note/Transcription/TranscriptionEngine.swift:41-65,69-94`
- Modify: `wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift:88-97,216-219`
- Modify: `wawa-note/Transcription/RemoteTranscriptionEngine.swift:14-18,51-53`
- Modify: `wawa-note/Domain/Services/ContentExtractionService.swift:259-297,341-346`

**Interfaces:**
- Consumes: `TranscriptionEngine` protocol, `AppleSpeechTranscriptionEngine`, `RemoteTranscriptionEngine`, `ContentExtractionService.transcribeSingleFile`
- Produces: `TranscriptionEngine` protocol with `onProgress`, `onCheckpoint`, `resumeFromChunk`, `finalize()`

**Background:** `ContentExtractionService` wires `onCheckpoint` and `resumeFromChunk` via typecast (`as? AppleSpeechTranscriptionEngine` / `as? RemoteTranscriptionEngine`). Any new engine silently loses checkpoint/resume capability — no compiler error, just silent data loss on interruption. The nil-out workaround before final write (lines 342-346) is a race-condition patch that `finalize()` eliminates.

- [ ] **Step 1: Add new properties and method to the protocol**

In `TranscriptionEngine.swift`, modify the protocol:

```swift
// ADD to TranscriptionEngine protocol (after line 64):
/// Progress callback — fired during chunking and per-chunk transcription.
var onProgress: ((TranscriptionProgress) -> Void)? { get set }

/// Checkpoint callback — fired after each successfully transcribed chunk.
/// Engine calls this with the cumulative transcript so far and the 1-based
/// index of the last completed chunk.
var onCheckpoint: ((Transcript, Int) -> Void)? { get set }

/// Resume offset — set before transcribeFile() to skip already-completed
/// chunks from a previous attempt. 0-based: value N means chunks 0..<N
/// are already done, start from chunk N.
var resumeFromChunk: Int { get set }

/// Called by the orchestrator after transcribeFile() completes successfully
/// to signal no more checkpoints will be emitted. The engine MUST nil out
/// its onCheckpoint reference to prevent late checkpoints from racing with
/// the final transcript write.
func finalize()
```

- [ ] **Step 2: Add default implementations**

In the `TranscriptionEngine` extension (after line 94):

```swift
// ADD after line 94:
extension TranscriptionEngine {
    var onProgress: ((TranscriptionProgress) -> Void)? {
        get { nil }
        set { /* no-op for engines that don't report progress */ }
    }

    var onCheckpoint: ((Transcript, Int) -> Void)? {
        get { nil }
        set { /* no-op for engines without checkpoint support */ }
    }

    var resumeFromChunk: Int {
        get { 0 }
        set { /* no-op for engines without resume support */ }
    }

    func finalize() {
        onCheckpoint = nil
        onProgress = nil
    }
}
```

- [ ] **Step 3: Remove stored properties that now come from protocol defaults in AppleSpeechTranscriptionEngine**

In `AppleSpeechTranscriptionEngine.swift`, remove the explicit `var onProgress`, `var onCheckpoint`, and `var resumeFromChunk` declarations (lines 93-97). They now come from the protocol. Keep the `private(set) var isCancelled` declaration. Add `finalize()`:

```swift
// REMOVE lines 93-97:
// var onProgress: ((TranscriptionProgress) -> Void)?
// var onCheckpoint: ((Transcript, Int) -> Void)?
// var resumeFromChunk: Int = 0

// ADD finalize() method (replaces implicit nil-out):
func finalize() {
    onCheckpoint = nil
    onProgress = nil
    isCancelled = false
}
```

- [ ] **Step 4: Same for RemoteTranscriptionEngine**

Remove lines 14-18 (`onProgress`, `onCheckpoint`, `resumeFromChunk`). Add `finalize()`:

```swift
func finalize() {
    onCheckpoint = nil
    onProgress = nil
    isCancelled = false
}
```

- [ ] **Step 5: Replace typecast-based wiring in ContentExtractionService**

Replace lines 259-262 (resumeFromChunk typecast):

```swift
// REPLACE:
// if let apple = engine as? AppleSpeechTranscriptionEngine {
//     apple.resumeFromChunk = checkpoint.completedChunks
// } else if let remote = engine as? RemoteTranscriptionEngine {
//     remote.resumeFromChunk = checkpoint.completedChunks
// }

// WITH:
engine.resumeFromChunk = checkpoint?.completedChunks ?? 0
```

Replace lines 293-297 (onCheckpoint typecast):

```swift
// REPLACE:
// if let apple = engine as? AppleSpeechTranscriptionEngine {
//     apple.onCheckpoint = checkpointSaver
// } else if let remote = engine as? RemoteTranscriptionEngine {
//     remote.onCheckpoint = checkpointSaver
// }

// WITH:
engine.onCheckpoint = checkpointSaver
```

Replace lines 341-346 (nil-out typecast):

```swift
// REPLACE:
// if let apple = engine as? AppleSpeechTranscriptionEngine {
//     apple.onCheckpoint = nil
// } else if let remote = engine as? RemoteTranscriptionEngine {
//     remote.onCheckpoint = nil
// }

// WITH:
engine.finalize()
```

- [ ] **Step 6: Build and verify no regressions**

```bash
make quick
```

- [ ] **Step 7: Commit**

```bash
git add wawa-note/Transcription/TranscriptionEngine.swift \
        wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift \
        wawa-note/Transcription/RemoteTranscriptionEngine.swift \
        wawa-note/Domain/Services/ContentExtractionService.swift
git commit -m "fix: add onCheckpoint/resumeFromChunk/finalize() to TranscriptionEngine protocol

Remove typecast-based wiring in ContentExtractionService. Any new engine
now gets checkpoint/resume support by default. finalize() replaces the
nil-out race-condition workaround. Default implementations are no-ops so
simple engines (no chunking) work unchanged.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Fix Checkpoint Resume Boundary — Seed `previousText` from Last Checkpoint Segment

**Files:**
- Modify: `wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift:280-284`
- Modify: `wawa-note/Transcription/RemoteTranscriptionEngine.swift:108-111`

**Interfaces:**
- Consumes: `deduplicateStart(_:against:)`, `TranscriptSegment.text`
- Produces: Correct dedup at checkpoint resume boundary

**Background:** On checkpoint resume, `previousText = ""` so `deduplicateStart` returns text unchanged for the first resumed chunk. The 1.5s overlap between the last checkpoint chunk and the first resumed chunk produces ~4 duplicated words in the merged transcript.

- [ ] **Step 1: Seed `previousText` from last checkpoint segment in AppleSpeechTranscriptionEngine**

After `let chunks = try await chunker.splitAudio(url: audioFileURL)` at line 280, modify the `previousText` initialization:

```swift
// REPLACE line 283:
// var previousText = ""

// WITH:
// Seed previousText from the last checkpoint segment so deduplicateStart
// correctly removes the 1.5s chunk overlap at the resume boundary.
var previousText: String
if startIndex > 0, let lastSegment = allSegments.last {
    previousText = lastSegment.text
} else {
    previousText = ""
}
```

- [ ] **Step 2: Same for RemoteTranscriptionEngine**

After `let startIndex = min(resumeFromChunk, chunks.count)` at line 110, modify:

```swift
// REPLACE line 105:
// var previousText = ""

// WITH:
var previousText: String
if startIndex > 0, let lastSegment = allSegments.last {
    previousText = lastSegment.text
} else {
    previousText = ""
}
```

- [ ] **Step 3: Add unit test for checkpoint resume dedup**

Add to `wawa-noteTests/CoreServicesTests.swift`:

```swift
func testCheckpointResumeDedup_preventsDuplicateTextAtBoundary() {
    // Given: "hello world this is a test" at end of chunk N
    // And overlap causes "a test welcome back everyone" at start of chunk N+1
    let previousText = "hello world this is a test"
    let overlappedText = "a test welcome back everyone"

    // Simulate deduplicateStart logic
    let prevWords = previousText.lowercased().split(separator: " ")
    let currWords = overlappedText.lowercased().split(separator: " ")
    let original = overlappedText.split(separator: " ").map(String.init)

    var maxMatch = 0
    for j in 1...min(10, prevWords.count, currWords.count) {
        if prevWords.suffix(j) == currWords.prefix(j) { maxMatch = j }
    }

    let deduped = maxMatch > 0 && maxMatch < original.count
        ? original.dropFirst(maxMatch).joined(separator: " ")
        : overlappedText

    // Then: "a test" should be removed, leaving "welcome back everyone"
    XCTAssertEqual(deduped, "welcome back everyone")
}

func testCheckpointResumeDedup_emptyPreviousText_returnsOriginal() {
    // When previousText is empty (no checkpoint, fresh start), no dedup
    let result = "hello world".split(separator: " ").map(String.init)
    XCTAssertEqual(result.joined(separator: " "), "hello world")
}
```

- [ ] **Step 4: Build and run tests**

```bash
make test
```

Expected: New tests pass. Existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift \
        wawa-note/Transcription/RemoteTranscriptionEngine.swift \
        wawa-noteTests/CoreServicesTests.swift
git commit -m "fix: seed previousText from last checkpoint segment for dedup at resume boundary

On checkpoint resume, previousText was empty string, so deduplicateStart
returned the first resumed chunk unchanged. The 1.5s audio overlap between
the last checkpoint chunk and the first resumed chunk caused ~4 duplicated
words in the merged transcript. Now seeded from allSegments.last.text.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Fix `OutputStream.write()` Return Value — Check for Truncated Multipart Body

**Files:**
- Modify: `wawa-note/Transcription/RemoteTranscriptionEngine.swift:370-448`

**Interfaces:**
- Consumes: `OutputStream.write(_:maxLength:)`, `InputStream.read(_:maxLength:)`
- Produces: `buildBodyFile(audioURL:prompt:model:boundary:outputURL:) throws` — now throws on write failure

**Background:** Two sites in `buildBodyFile` discard `OutputStream.write()` return value with `_ =`. A partial write or -1 error silently truncates the multipart body sent to the Whisper API. Server receives corrupt audio → confusing HTTP 400 or partial transcript with incorrect timestamps.

- [ ] **Step 1: Replace `_ =` with checked write helper**

Replace the local `write` function (lines 382-388) and all `output.write` calls:

```swift
// REPLACE lines 382-388:
// func write(_ s: String) {
//     if let d = s.data(using: .utf8) {
//         _ = d.withUnsafeBytes {
//             output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count)
//         }
//     }
// }

// WITH:
enum BodyWriteError: Error, LocalizedError {
    case writeFailed(Int)
    case partialWrite(expected: Int, actual: Int)
    var errorDescription: String? {
        switch self {
        case .writeFailed(let code): return "OutputStream write failed with code \(code)"
        case .partialWrite(let expected, let actual):
            return "OutputStream partial write: \(actual)/\(expected) bytes"
        }
    }
}

func write(_ s: String) throws {
    guard let d = s.data(using: .utf8) else { return }
    let written = try d.withUnsafeBytes { ptr -> Int in
        let result = output.write(
            ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count)
        if result < 0 {
            throw BodyWriteError.writeFailed(result)
        }
        return result
    }
    if written != d.count {
        throw BodyWriteError.partialWrite(expected: d.count, actual: written)
    }
}
```

- [ ] **Step 2: Update the audio data write loop to check return value**

Replace lines 432-445:

```swift
// REPLACE lines 432-445:
// let bufferSize = 65_536
// var buffer = [UInt8](repeating: 0, count: bufferSize)
// while input.hasBytesAvailable {
//     let bytesRead = input.read(&buffer, maxLength: bufferSize)
//     if bytesRead > 0 {
//         output.write(buffer, maxLength: bytesRead)
//     } else if bytesRead < 0 {
//         throw input.streamError ?? ...
//     } else {
//         break
//     }
// }

// WITH:
let bufferSize = 65_536
var buffer = [UInt8](repeating: 0, count: bufferSize)
while input.hasBytesAvailable {
    let bytesRead = input.read(&buffer, maxLength: bufferSize)
    if bytesRead > 0 {
        let written = output.write(buffer, maxLength: bytesRead)
        if written < 0 {
            throw BodyWriteError.writeFailed(written)
        }
        if written != bytesRead {
            throw BodyWriteError.partialWrite(expected: bytesRead, actual: written)
        }
    } else if bytesRead < 0 {
        throw input.streamError
            ?? NSError(
                domain: "body", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Error reading audio file"])
    } else {
        break  // EOF
    }
}
```

- [ ] **Step 3: Update method signature and all `write()` calls to use `try`**

All existing `write("...")` calls in `buildBodyFile` (lines 390-418, 447-448) must become `try write("...")`. The method already `throws`, so callers are unaffected.

- [ ] **Step 4: Build and verify**

```bash
make quick
```

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Transcription/RemoteTranscriptionEngine.swift
git commit -m "fix: check OutputStream.write() return value in multipart body construction

Replace discarded _ = output.write() with checked throws-on-failure helper.
Partial writes and write errors (-1) silently truncated the multipart body
sent to the Whisper API, producing corrupt uploads with confusing HTTP 400
responses or partial transcripts with incorrect timestamps.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Fix Remote Engine Missing `meetingId` in `Transcript` (verbose_json Path)

**Files:**
- Modify: `wawa-note/Transcription/RemoteTranscriptionEngine.swift:294-335`

**Interfaces:**
- Consumes: `Transcript`, `TranscriptSegment`, `meetingId: UUID`
- Produces: `Transcript` with `meetingId` set in all paths

**Background:** The `verbose_json` response path at line 310 returns `Transcript(languageCode:..., segments:..., sourceEngineId:...)` **without** `meetingId`. The Apple engine always sets it via `buildTranscript`. Any downstream code reading `transcript.meetingId` from disk gets `nil` for Whisper transcriptions only — grouping, export, and analytics break silently.

- [ ] **Step 1: Add `meetingId` to verbose_json path**

Replace line 310-315:

```swift
// REPLACE lines 310-315:
// return Transcript(
//     languageCode: json["language"] as? String,
//     segments: segments,
//     sourceEngineId: id
// )

// WITH:
return Transcript(
    meetingId: meetingId,
    languageCode: json["language"] as? String,
    segments: segments,
    sourceEngineId: id
)
```

- [ ] **Step 2: Add `meetingId` to fallback plain-text path**

Replace line 325-335:

```swift
// REPLACE lines 325-335:
// return Transcript(
//     languageCode: json["language"] as? String,
//     segments: [TranscriptSegment(...)],
//     sourceEngineId: id
// )

// WITH:
return Transcript(
    meetingId: meetingId,
    languageCode: json["language"] as? String,
    segments: [
        TranscriptSegment(
            meetingId: meetingId, startTime: 0,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceEngineId: id
        )
    ],
    sourceEngineId: id
)
```

- [ ] **Step 3: Build and verify**

```bash
make quick
```

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Transcription/RemoteTranscriptionEngine.swift
git commit -m "fix: set meetingId on Transcript in all Remote engine response paths

verbose_json and plain-text paths both omitted meetingId while the Apple
engine's buildTranscript always sets it. Downstream code reading
transcript.meetingId from disk received nil for Whisper transcriptions,
breaking grouping, export, and analytics.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Fix `cleanupOrphanedRecordings` — Recover Items Stuck in `.transcribing`

**Files:**
- Modify: `wawa-note/Connectivity/RecordingCoordinator.swift:775-889`

**Interfaces:**
- Consumes: `ModelContext`, `KnowledgeItem.statusRaw`, `ProcessingQueueService`
- Produces: Recovers items in `.transcribing`, `.queuedForTranscription`, and `.analyzing` states

**Background:** The query at line 783-785 only matches `statusRaw == "recording"`. Items that crashed during pipeline processing (`.transcribing`, `.queuedForTranscription`, `.analyzing`) are never recovered. The `ProcessingQueue` is in-memory (not persisted), so these items remain stuck forever with no UI path to retry.

- [ ] **Step 1: Expand the orphan query to include all non-terminal states**

Replace lines 783-789:

```swift
// REPLACE lines 783-789:
// let descriptor = FetchDescriptor<KnowledgeItem>(
//     predicate: #Predicate { $0.statusRaw == "recording" })
// guard let orphans = try? bgContext.fetch(descriptor), !orphans.isEmpty else { return }

// WITH:
// Recover items stuck in any non-terminal pipeline state after a crash.
// .recording: recording was in progress
// .queuedForTranscription: was enqueued but never started
// .transcribing: transcription was in progress
// .preparingAudio: concatenation was in progress
// .analyzing: analysis was in progress
let recoverableStates = ["recording", "queuedForTranscription", "transcribing",
                          "preparingAudio", "analyzing"]
let descriptor = FetchDescriptor<KnowledgeItem>(
    predicate: #Predicate { recoverableStates.contains($0.statusRaw) })
guard let orphans = try? bgContext.fetch(descriptor), !orphans.isEmpty else {
    // Also check for .recorded items with broken M4A (existing logic)
    // ... (existing broken M4A check continues below)
}
```

- [ ] **Step 2: Handle each stuck state appropriately**

After the fetch, add per-state recovery logic:

```swift
// ADD after the existing fetch block (~line 789):
var recoveredIds: [UUID] = []
for item in orphans {
    AppLog.audio.info("Recovering stuck item: \(item.id) state=\(item.statusRaw)")
    let store = FileArtifactStore()

    // Items stuck in .transcribing: transcription was interrupted.
    // Reset to .recorded — the pipeline will restart transcription.
    // If transcript_checkpoint.json exists, ContentExtractionService
    // will resume from the last successful chunk.
    if item.statusRaw == "transcribing" {
        guard store.audioFileExists(for: item.id) || store.recordingManifestExists(for: item.id) else {
            item.status = .failed
            continue
        }
        item.status = .recorded
        item.audioFileRelativePath = AppFileConstants.audioFileName
        recoveredIds.append(item.id)
        continue
    }

    // Items stuck in .queuedForTranscription: never started.
    // Reset to .recorded — same as above.
    if item.statusRaw == "queuedForTranscription" {
        guard store.audioFileExists(for: item.id) || store.recordingManifestExists(for: item.id) else {
            item.status = .failed
            continue
        }
        item.status = .recorded
        item.audioFileRelativePath = AppFileConstants.audioFileName
        recoveredIds.append(item.id)
        continue
    }

    // Items stuck in .preparingAudio: concatenation was interrupted.
    // AudioSegmentConcatenator may have left a broken M4A.
    if item.statusRaw == "preparingAudio" {
        guard store.recordingManifestExists(for: item.id) else {
            item.status = .failed
            continue
        }
        item.status = .recorded
        recoveredIds.append(item.id)
        continue
    }

    // Items stuck in .analyzing: analysis was interrupted.
    // Keep .transcribed state so the pipeline re-runs analysis only.
    if item.statusRaw == "analyzing" {
        item.status = .transcribed
        recoveredIds.append(item.id)
        continue
    }

    // Items stuck in .recording: original recovery logic
    guard store.audioFileExists(for: item.id) || store.recordingManifestExists(for: item.id) else {
        item.status = .failed
        continue
    }
    item.status = .recorded
    item.audioFileRelativePath = AppFileConstants.audioFileName
    recoveredIds.append(item.id)
}
```

- [ ] **Step 3: Clear stale `transcript_checkpoint.json` before re-enqueuing repaired items**

In the M4A repair loop (after line 833), add checkpoint cleanup:

```swift
// ADD after line 833 (after concatenation succeeds):
// Clear any stale checkpoint from the previous transcription attempt.
// The repaired audio.m4a may differ in duration from the original,
// making the old checkpoint indices invalid.
let checkpointURL = store.meetingDirectoryURL(for: itemId)
    .appendingPathComponent("transcript_checkpoint.json")
if FileManager.default.fileExists(atPath: checkpointURL.path) {
    try? FileManager.default.removeItem(at: checkpointURL)
    AppLog.audio.info("Cleared stale checkpoint for repaired item \(itemId.uuidString.prefix(8))")
}
```

- [ ] **Step 4: Do the same for recovered items being enqueued**

In the recovered items loop (~line 864), add the same checkpoint cleanup before enqueue:

```swift
// ADD before capturedQueue?.enqueue(...) at ~line 873:
let checkpointURL = FileArtifactStore().meetingDirectoryURL(for: itemId)
    .appendingPathComponent("transcript_checkpoint.json")
if FileManager.default.fileExists(atPath: checkpointURL.path) {
    try? FileManager.default.removeItem(at: checkpointURL)
    AppLog.audio.info("Cleared stale checkpoint for recovered item \(itemId.uuidString.prefix(8))")
}
```

- [ ] **Step 5: Build and verify**

```bash
make quick
```

- [ ] **Step 6: Commit**

```bash
git add wawa-note/Connectivity/RecordingCoordinator.swift
git commit -m "fix: recover items stuck in .transcribing/.analyzing after crash

Expand orphan query from statusRaw='recording' to include all non-terminal
pipeline states. Items stuck in .transcribing are reset to .recorded so the
pipeline restarts transcription (using checkpoint resume). Items in .analyzing
reset to .transcribed. Clear stale transcript_checkpoint.json before
re-enqueuing items with repaired M4A to prevent resume from mismatched chunks.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Fix Re-Transcription Gate — Allow Re-Transcription on Engine/Locale Change

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift:247-248`

**Interfaces:**
- Consumes: `KnowledgeItem.transcriptionEngineId`, `TranscriptionSettings.shared.mode`, `ContentExtractionService`
- Produces: Re-transcription when engine or locale changes

**Background:** `item.transcriptionEngineId == nil` gate at line 248 means once an item is transcribed, it's **never** re-transcribed. If the user changes from Apple to Whisper, or changes the locale, the pipeline silently reuses the old transcript.

- [ ] **Step 1: Replace the gate with engine-aware comparison**

Replace line 248:

```swift
// REPLACE line 248:
// if item.type == .audio, item.transcriptionEngineId == nil {

// WITH:
// Re-transcribe when: (a) never transcribed, or (b) engine/locale changed
let needsTranscription: Bool
if item.transcriptionEngineId == nil {
    needsTranscription = true
} else {
    // Engine changed? (e.g., Apple → Whisper)
    let currentEngine = TranscriptionSettings.shared.mode == .whisper
        ? "remote-whisper" : "apple-speech"
    let engineChanged = item.transcriptionEngineId != currentEngine
        && item.transcriptionEngineId != "apple-cloud"  // cloud fallback variant
    // Locale changed? (different locale = different transcript)
    let localeChanged = item.languageCode != preferredLocale
        && preferredLocale != nil
    needsTranscription = engineChanged || localeChanged
}

if item.type == .audio, needsTranscription {
```

- [ ] **Step 2: Clear existing transcript when re-transcribing**

Before `extractTextFromAudio` (after the `if needsTranscription` block), clear the old transcript:

```swift
// ADD after the item.status = .transcribing line (~line 255):
if item.transcriptionEngineId != nil && needsTranscription {
    // Clear old transcript before re-transcription
    try? fileStore.deleteArtifact("transcript.json", meetingId: itemID)
    try? FileManager.default.removeItem(
        at: fileStore.meetingDirectoryURL(for: itemID)
            .appendingPathComponent("transcript_checkpoint.json"))
    AppLog.transcription.info(
        "Re-transcribing item \(itemID.uuidString.prefix(8)) — engine/locale changed, old transcript cleared"
    )
}
```

- [ ] **Step 3: Build and verify**

```bash
make quick
```

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift
git commit -m "fix: allow re-transcription when engine or locale changes

Replace transcriptionEngineId == nil gate with engine-aware comparison.
When user switches from Apple to Whisper or changes locale, old transcript
is cleared and item is re-transcribed instead of silently reusing stale data.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Fix `processEntry` Timeout — Scale with Expected Transcription Duration

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift:855-904`

**Interfaces:**
- Consumes: `KnowledgeItem.durationSeconds`, `TranscriptionSettings.shared.mode`, `processEntry`
- Produces: Dynamic polling timeout scaled to audio duration and engine type

**Background:** The 120s hard timeout (24 × 5s polling) is too short for on-device transcription of long audio. A 30-minute recording takes ~15 minutes on-device. The timeout fires, `processEntry` returns, the queue retries up to 3 times, all fail with timeout → permanently failed — while the original pipeline **still completes successfully** in the background.

- [ ] **Step 1: Compute dynamic timeout from audio duration and engine type**

Replace lines 866-867:

```swift
// REPLACE lines 866-867:
// Task { @MainActor in
//     let maxAttempts = 24  // 24 × 5s = 120s total

// WITH:
Task { @MainActor in
    // Dynamic timeout: on-device transcription is CPU-bound, ~0.5× real-time
    // on iPhone 14 Plus. Remote Whisper is network-bound, ~0.1-0.3× real-time.
    // Base: 120s minimum. Scale: 2× audio duration for on-device, 1× for remote.
    let audioDuration = item.durationSeconds ?? 60
    let isOnDevice = TranscriptionSettings.shared.mode == .apple
    let scaleFactor = isOnDevice ? 2.0 : 0.5
    let timeoutSeconds = max(120, audioDuration * scaleFactor)
    let maxAttempts = max(24, Int(timeoutSeconds / 5.0))  // Poll every 5s
    AppLog.transcription.info(
        "processEntry polling: timeout=\(Int(timeoutSeconds))s attempts=\(maxAttempts) duration=\(Int(audioDuration))s onDevice=\(isOnDevice)"
    )
```

- [ ] **Step 2: Keep existing terminal-state early-exit logic**

The rest of the polling loop (lines 868-903) remains unchanged — it still checks for terminal states and exits early on `analyzed`, `failed`, or `pendingReview`. The dynamic timeout only extends the maximum wait.

- [ ] **Step 3: Build and verify**

```bash
make quick
```

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift
git commit -m "fix: scale processEntry polling timeout to audio duration

Replace fixed 120s timeout with dynamic scaling: 2× audio duration for
on-device, 0.5× for remote. A 30-minute on-device transcription needs
~900s — the fixed 120s caused false timeout → retry → permanent failure
while the pipeline still completed successfully in the background.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Fix `AudioChunker` Overlap — Apply `overlap` Parameter to Chunk Boundaries

**Files:**
- Modify: `wawa-note/Domain/Services/AudioChunker.swift:46-77`

**Interfaces:**
- Consumes: `chunkDuration: TimeInterval`, `overlap: TimeInterval`
- Produces: Overlapping chunk descriptors used by `exportChunk`

**Background:** `AudioChunker` stores `overlap` (default 1.5s for Apple, 0s for Remote) but `splitAudio()` builds chunks with exact boundaries (`currentStart = chunkEnd`). The overlap context that `AppleSpeechTranscriptionEngine` expects (and `deduplicateStart` handles) is never present — the recognizer loses language model context at every chunk boundary, degrading accuracy for words near 50s boundaries.

- [ ] **Step 1: Apply overlap when building chunk descriptors**

Replace the chunk descriptor building loop (lines 67-77):

```swift
// REPLACE lines 67-77:
// var currentStart: TimeInterval = 0
// var idx = 0
// while currentStart < totalSeconds {
//     let chunkEnd = min(currentStart + chunkDuration, totalSeconds)
//     let outputURL = tempDir.appendingPathComponent("chunk_\(idx).m4a")
//     descriptors.append(
//         ChunkDescriptor(index: idx, start: currentStart, end: chunkEnd, url: outputURL))
//     currentStart = chunkEnd
//     idx += 1
// }

// WITH:
var currentStart: TimeInterval = 0
var idx = 0
// overlap == 0 for remote engine (no dedup needed), >0 for on-device
let effectiveOverlap = overlap > 0 && totalSeconds > chunkDuration ? overlap : 0

while currentStart < totalSeconds {
    let chunkEnd = min(currentStart + chunkDuration, totalSeconds)
    let outputURL = tempDir.appendingPathComponent("chunk_\(idx).m4a")
    descriptors.append(
        ChunkDescriptor(index: idx, start: currentStart, end: chunkEnd, url: outputURL))
    // Advance by chunkDuration minus overlap so the next chunk includes
    // `overlap` seconds of context from the end of this chunk.
    currentStart = chunkEnd - effectiveOverlap
    idx += 1
}
```

- [ ] **Step 2: Adjust `AudioChunk.startTime` to reflect true position**

The `AudioChunk.startTime` in the `chunks` array (line 95, 106) uses `desc.start`, but with overlap the actual start of the exported audio is wrong. Instead, compute the true position for timestamp adjustments:

```swift
// REPLACE lines 94-96 (inside the for-loop where chunks are appended):
// chunks.append(
//     AudioChunk(url: desc.url, startTime: desc.start, duration: desc.end - desc.start))

// WITH:
// startTime is the true position in the original audio, NOT adjusted for
// overlap — the engine uses this to offset segment timestamps.
chunks.append(
    AudioChunk(url: desc.url, startTime: desc.start, duration: desc.end - desc.start))
```

No change needed — `desc.start` is already correct because we advance `currentStart = chunkEnd - overlap` for the next chunk, but the current chunk's `start` was set from the unmodified `currentStart`.

- [ ] **Step 3: Update `AudioChunk` struct to expose effective overlap for dedup**

Add an `overlapStart: TimeInterval` field:

```swift
// MODIFY AudioChunk struct (line 4-8):
struct AudioChunk {
    let url: URL
    let startTime: TimeInterval
    let duration: TimeInterval
    /// When non-zero, the first `overlapStart` seconds of this chunk overlap
    /// with the previous chunk and should be deduplicated.
    var overlapStart: TimeInterval = 0
}
```

And set it when building chunks:

```swift
// ADD after line 95 (inside the for loop):
let hasOverlap = effectiveOverlap > 0 && idx > 0
chunks.append(
    AudioChunk(
        url: desc.url, startTime: desc.start,
        duration: desc.end - desc.start,
        overlapStart: hasOverlap ? effectiveOverlap : 0))
```

- [ ] **Step 4: Use `overlapStart` in engines' chunk loops**

In both `AppleSpeechTranscriptionEngine.transcribeFile` (~line 350) and `RemoteTranscriptionEngine.transcribeFile` (~line 179), replace:

```swift
// REPLACE:
// var text = segment.text
// if i > 0 || startIndex > 0 { text = deduplicateStart(text, against: previousText) }

// WITH:
// When the chunk has overlap, segments within the overlap window should be
// deduplicated against the previous chunk's ending text.
let isOverlapSegment = chunk.overlapStart > 0
    && segment.startTime < chunk.overlapStart
var text = segment.text
if isOverlapSegment && (i > 0 || startIndex > 0) {
    text = deduplicateStart(text, against: previousText)
}
```

- [ ] **Step 5: Build and verify**

```bash
make quick
```

- [ ] **Step 6: Commit**

```bash
git add wawa-note/Domain/Services/AudioChunker.swift \
        wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift \
        wawa-note/Transcription/RemoteTranscriptionEngine.swift
git commit -m "fix: apply AudioChunker overlap parameter to chunk boundaries

Previously splitAudio built chunks with exact boundaries (currentStart =
chunkEnd), ignoring the overlap parameter entirely. Now advances by
chunkDuration - overlap so each chunk includes context from the previous
chunk's tail. Added overlapStart to AudioChunk so engines only dedup
segments within the overlap window, not the entire chunk. Fixes lost
language model context at chunk boundaries degrading recognition accuracy.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: Fix Cloud Fallback Task Leak — Cancel Original On-Device Task

**Files:**
- Modify: `wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift:463-501`

**Interfaces:**
- Consumes: `SFSpeechRecognitionTask.cancel()`, `activeRecognitionTask`
- Produces: Clean cancellation of on-device task before cloud fallback

**Background:** When the cloud fallback fires, a new `cloudTask` is created and `activeRecognitionTask` is replaced — but the original `recognitionTask` is **never cancelled**. It continues processing the full audio buffer in background, consuming CPU and ~50 MB memory. In long transcriptions with many chunk failures, accumulated tasks waste significant resources.

- [ ] **Step 1: Cancel the original task before creating cloud fallback**

In `transcribeDirect`, after detecting `kAFAssistantErrorDomain Code=1101` and before creating the cloud request, add:

```swift
// ADD after line 468 (after "Retry once with cloud recognition"):
// Cancel the original on-device task before starting cloud fallback.
// Without this, the on-device task continues processing in background,
// consuming CPU and memory for the full audio buffer duration.
recognitionTask?.cancel()
self.activeRecognitionTask = nil
```

- [ ] **Step 2: Also cancel recognitionTask on timeout**

In the timeout `DispatchWorkItem` (line 444), the existing code already calls `recognitionTask?.cancel()`. Verify it's present:

```swift
// Line 447 should already have:
// recognitionTask?.cancel()
```

- [ ] **Step 3: Build and verify**

```bash
make quick
```

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift
git commit -m "fix: cancel on-device recognition task before cloud fallback

When kAFAssistantErrorDomain triggers cloud fallback, cancel the original
SFSpeechRecognitionTask before creating the cloud task. Without this, the
on-device task continues processing in background indefinitely, wasting CPU
and ~50 MB per failed chunk. In long transcriptions with many chunk failures,
accumulated tasks degrade performance significantly.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 14: Fix Manifest Divergence — Use Manifest as Source of Truth for Segment Indices

**Files:**
- Modify: `wawa-note/Audio/AudioFileWriter.swift:367-456`
- Modify: `wawa-note/Connectivity/RecordingCoordinator.swift:128-157,706-751`

**Interfaces:**
- Consumes: `RecordingManifest`, `ClosedSegmentInfo`, `RecordingSegment`, `nextSegmentIndexProvider`
- Produces: Consistent segment indexing via manifest, safe overwrite avoidance with gap detection

**Background:** When `AudioFileWriter._openSegment` skips an index (overwrite avoidance), the manifest records the pre-adjustment index while the file is written at the adjusted index. This causes: (a) manifest references to non-existent files, (b) orphan segment creation in `onSegmentClosed`, (c) duplicated audio in `AudioSegmentConcatenator`. The manifest must be the single source of truth for indices, with the writer following its lead.

- [ ] **Step 1: In `AudioFileWriter`, remove index auto-adjustment — delegate to manifest**

In `_openSegment`, replace the overwrite-avoidance index scan (lines 397-447) with:

```swift
// REPLACE lines 397-447 (the overwrite-avoidance scan block starting at
// "CRITICAL: never overwrite an existing segment file"):
// The manifest is the source of truth for segment indices. The writer
// must NOT auto-adjust indices — that creates divergence between the
// file system and the manifest. If a segment file already exists at the
// requested index, the caller (RecordingCoordinator) passed a wrong index
// and must be corrected before calling this method.

if fileManager.fileExists(atPath: fileURL.path) {
    let existingSize =
        (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
    if existingSize > 0 {
        AppLog.audio.error(
            "Segment \(self._segmentIndex): \(fileName) already exists (\(existingSize) bytes) — "
            + "manifest index collision. This is a bug in the caller — the manifest "
            + "should have provided the next free index via nextSegmentIndexProvider.")
        // DO NOT auto-adjust. The caller must fix the manifest-to-writer index sync.
        throw AudioFileWriterError.fileCreationFailed
    }
    AppLog.audio.info(
        "Segment \(self._segmentIndex): \(fileName) exists but is 0 bytes — safe to reuse")
}

self._audioFile = try AVAudioFile(
    forWriting: fileURL, settings: settings,
    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
self._currentFileURL = fileURL
AppLog.audio.info("Segment \(self._segmentIndex): \(fileName) \(sampleRate)Hz PCM")
```

- [ ] **Step 2: In `RecordingCoordinator`, make `nextSegmentIndexProvider` gap-aware**

The existing provider at lines 163-166 returns `(max index + 1)`, which is correct after removing the writer's auto-adjustment. Add a validation step in `onSegmentCreated` (line 105-119):

```swift
// ADD after line 106 (inside onSegmentCreated closure, before manifest mutation):
// Validate that the writer's index matches what the manifest expects.
// After removing auto-adjustment in AudioFileWriter, a mismatch indicates a bug.
if let info = closedInfo {
    let expectedNextIndex = (m.segments.map(\.index).max() ?? -1) + 1
    if info.index != expectedNextIndex {
        AppLog.audio.error(
            "Segment index mismatch: writer returned \(info.index), manifest expected \(expectedNextIndex). "
            + "This indicates a stale nextSegmentIndexProvider value.")
    }
}
```

- [ ] **Step 3: Fix crash recovery manifest to handle non-contiguous indices**

In `attemptCrashCheckpointRecovery` (lines 706-723), instead of generating a contiguous 0...segmentIndex range, read actual files on disk:

```swift
// REPLACE lines 711-723:
// segments: (0...segmentIndex).map { i in ... }

// WITH:
// Build manifest from actual segment files on disk, not a contiguous range.
// AudioFileWriter previously auto-adjusted indices during overwrite avoidance,
// so disk segments may have gaps (e.g., 0, 1, 5 instead of 0, 1, 2).
let store = FileArtifactStore()
let segmentsDir = store.segmentsDirectoryURL(for: meetingId)
let existingSegments: [RecordingSegment] = (try? FileManager.default
    .contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: [.fileSizeKey])
    .filter { $0.pathExtension == "wav" }
    .compactMap { url -> RecordingSegment? in
        let name = url.lastPathComponent
        // Parse "segment-003.wav" → index 3
        guard let indexStr = name.components(separatedBy: "-").last?
            .components(separatedBy: ".").first,
            let index = Int(indexStr) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return nil }
        return RecordingSegment(
            id: UUID(), index: index, fileName: name,
            startedAt: item.createdAt,
            inputPortName: "recovered", inputPortType: "recovered",
            routeChangeReason: "crash_recovery",
            sampleRate: sampleRate)
    }
    .sorted(by: { $0.index < $1.index })) ?? []

let segments = existingSegments.isEmpty
    ? []  // No segments found — empty manifest, will be handled downstream
    : existingSegments
```

- [ ] **Step 4: Build and verify**

```bash
make quick
```

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Audio/AudioFileWriter.swift \
        wawa-note/Connectivity/RecordingCoordinator.swift
git commit -m "fix: use manifest as single source of truth for segment indices

Remove AudioFileWriter auto-index-adjustment during overwrite avoidance —
the manifest (via nextSegmentIndexProvider) now owns the index space.
Fix crash recovery to enumerate actual segment files on disk instead of
assuming a contiguous 0...segmentIndex range. Prevents manifest-to-disk
index divergence that caused duplicate audio in concatenation and orphan
segment references.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 15: Fix Manifest Write Race — Single Save Path at Stop

**Files:**
- Modify: `wawa-note/Connectivity/RecordingCoordinator.swift:105-158,428-508`

**Interfaces:**
- Consumes: `onSegmentCreated`, `onSegmentClosed`, `stopRecording()`, `saveManifest`
- Produces: Single manifest write at recording stop, in-memory updates only during recording

**Background:** Three code paths save the manifest: `onSegmentCreated` (Task MainActor), `onSegmentClosed` (Task MainActor), and `stopRecording` (synchronous). The fire-and-forget Tasks can execute AFTER `stopRecording` saves the final manifest, overwriting `endedAt` and segment metadata with stale data.

- [ ] **Step 1: Remove `saveManifest` calls from `onSegmentCreated` and `onSegmentClosed`**

In `onSegmentCreated` (lines 115-117), remove:

```swift
// REMOVE lines 115-117:
// if let itemId = self.savedItemId {
//     self.saveManifest(m, meetingId: itemId)
// }
```

In `onSegmentClosed` (lines 154-156), remove:

```swift
// REMOVE lines 154-156:
// if let itemId = self.savedItemId {
//     self.saveManifest(m, meetingId: itemId)
// }
```

- [ ] **Step 2: Add periodic checkpoint save during recording (every 30s)**

Replace the removed per-segment saves with a periodic timer-based save in `startObservation` (or a dedicated timer). Add to `startRecording`:

```swift
// ADD in startRecording, after startObservation() (~line 278):
startPeriodicManifestSave()
```

And add the method:

```swift
private var manifestSaveTask: Task<Void, Never>?

private func startPeriodicManifestSave() {
    manifestSaveTask?.cancel()
    manifestSaveTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
            guard let self, let m = self.manifest, let itemId = self.savedItemId else { continue }
            self.saveManifest(m, meetingId: itemId)
        }
    }
}

private func stopPeriodicManifestSave() {
    manifestSaveTask?.cancel()
    manifestSaveTask = nil
}
```

- [ ] **Step 3: Save manifest only at stop (final) + periodic (crash recovery)**

The `stopRecording()` already does the final save (line 458). Add cleanup:

```swift
// ADD in stopRecording, after line 448 (after nowPlayingTimer?.invalidate()):
stopPeriodicManifestSave()
```

- [ ] **Step 4: Build and verify**

```bash
make quick
```

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Connectivity/RecordingCoordinator.swift
git commit -m "fix: single manifest save path to prevent write race

Remove per-segment saveManifest calls from onSegmentCreated/onSegmentClosed.
Replace with periodic 30s save for crash recovery + final save at stop.
Three concurrent save paths (2 fire-and-forget Tasks + 1 synchronous) could
interleave — the onSegmentClosed Task running after stopRecording would
overwrite the finalized manifest with stale segment data missing endedAt.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Implementation Order

| Phase | Tasks | Dependency | Risk |
|-------|-------|-----------|------|
| **Phase 1** | T1-T4 (crash fixes) | None | Low — isolated changes |
| **Phase 2** | T5-T8 (protocol + data integrity) | Depends on T1 (protocol changes touch same files) | Medium — protocol changes affect all engines |
| **Phase 3** | T9-T15 (re-transcription + manifest) | Depends on T5 (uses new protocol members) | Medium — manifest changes affect recording flow |

**Recommended execution:** Phase 1 → test on device → Phase 2 → test on device → Phase 3 → full regression test with multi-hour recording.

## Verification

After all phases complete, run the full validation:

```bash
# 1. Unit tests
make test

# 2. Build + deploy to iPhone 14 Plus
make all DEVICE=14plus

# 3. Manual test: record 10-minute meeting → stop → verify transcript
# 4. Manual test: record 30-minute meeting → force-kill mid-transcription → relaunch → verify resume
# 5. Manual test: switch engine (Apple → Whisper) → verify re-transcription
# 6. Manual test: Bluetooth route change during recording → verify no gaps/duplicates
# 7. Manual test: fill storage to near-full → record → verify graceful error
```
