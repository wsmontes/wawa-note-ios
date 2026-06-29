# Audio Pipeline Bug Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 12 bugs discovered in the audio import → transcription pipeline, prioritized P0→P3.

**Architecture:** Each task targets one file (or two closely related ones). Fixes are mechanical — add guards, timeouts, validation checks. No new abstractions or refactors. The ContentPipelineService split (Task 9) is deferred because it requires architecture discussion.

**Tech Stack:** Swift 5.9+, SwiftData, AVFoundation, Speech, UIKit (Share Extension)

## Global Constraints

- Target iOS 17.0+
- Use `AppLog` for logging (not `print` or `os_log` directly)
- Use `try?` only for non-critical paths; critical validation uses `try` + `catch`
- Follow existing naming patterns in each file
- Files are in `wawa-note.xcodeproj/project.pbxproj` — do NOT add new files without explicit approval (all fixes are edits to existing files)
- Test by building (`make quick` or xcodebuild) — no new test files created
- Every commit message must be prefixed with `fix:` and reference the file being changed

---

### Task 1: AudioSegmentConcatenator — guard against all-segments-skipped silent M4A

**Files:**
- Modify: `wawa-note/Audio/AudioSegmentConcatenator.swift:79-127`

**Interfaces:**
- Consumes: `RecordingManifest.segments`, `FileArtifactStore.segmentURL(for:fileName:)`
- Produces: `concatenate(manifest:meetingId:) -> Bool` (unchanged signature)

**Problem:** When all WAV segments are invalid (missing audio track, zero duration), the composition is empty but export still runs. Result: `audio.m4a` with no audio content, reported as success.

- [ ] **Step 1: Add skippedCount guard before export**

In `AudioSegmentConcatenator.concatenate()`, after the multi-segment composition loop (after line 107), add a guard that returns false when ALL segments were skipped:

```swift
// After the for url in urls loop ends (line 107), before `guard let export` (line 108):

guard skippedCount < urls.count else {
    AppLog.audio.error("SegmentConcatenator: all \(urls.count) segments skipped — no valid audio tracks")
    return false
}
```

- [ ] **Step 2: Verify existing logging still works**

The existing `if skippedCount > 0` warning at line 120 already handles partial skips. Confirm it still compiles after adding the guard above it:

```swift
// Lines 118-121 should remain unchanged:
if export.status == .completed {
    AppLog.event("audio", "Segments concatenated → audio.m4a (\(urls.count) segments)")
    if skippedCount > 0 {
        AppLog.audio.warning("SegmentConcatenator: \(skippedCount)/\(urls.count) segments skipped during concat")
    }
```

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Audio/AudioSegmentConcatenator.swift
git commit -m "fix: guard against all-segments-skipped producing silent M4A

When every WAV segment lacks a valid audio track (zero duration or
missing), the AVMutableComposition is empty but export still runs,
producing a tiny 'valid' M4A with no audio content. Add explicit
guard before export — if skippedCount == urls.count, return false
so the caller can mark the item as failed and preserve WAV segments.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: ContentExtractionService — remove ModelContext saves + fix force-unwrap

**Files:**
- Modify: `wawa-note/Domain/Services/ContentExtractionService.swift:104-127,155-162,187-235`

**Interfaces:**
- Consumes: `KnowledgeItemService.fetchItem(id:)`, `ModelContext.save()`
- Produces: `extractTextFromAudio(_:) -> String?` (unchanged signature)
- Produces: `resolveTranscriptionEngine(preferredLocale:) -> TranscriptionEngine?` (unchanged signature)

**Problem 1:** `extractTextFromAudio` saves item status changes on its own `modelContext`, racing with `ContentPipelineService` which also saves the same item on a different context. Remove the saves from ContentExtractionService — the caller (ContentPipelineService) owns the save responsibility.

**Problem 2:** `resolveTranscriptionEngine` force-unwraps `config.baseURL!` at line 162. While currently safe (previous line guards it with a `let` binding), the pattern is fragile.

- [ ] **Step 1: Remove modelContext saves from validation block**

Replace lines 104-137 in `extractTextFromAudio`. The three validation checks (audio missing, too small, too short) currently do `fetchItem` + `modelContext.save()`. Remove those — just log and return nil:

```swift
// Replace lines 104-127 with:

guard audioExists else {
    AppLog.audio.error("Transcription validation FAILED: final audio missing")
    return nil
}
guard audioSize > 4096 else {
    AppLog.audio.error("Transcription validation FAILED: audio too small (\(audioSize) bytes)")
    return nil
}
guard audioDuration >= 1.0 else {
    AppLog.audio.error("Transcription validation FAILED: audio too short (\(String(format: "%.1f", audioDuration))s)")
    return nil
}
if hasManifest, let m = manifest, !m.segments.isEmpty, sumSegmentDurations > 0 {
    let ratio = audioDuration / sumSegmentDurations
    if ratio < 0.3 || ratio > 2.5 {
        AppLog.audio.warning(
            "Transcription validation: consolidated audio duration (\(String(format: "%.1f", audioDuration))s) deviates from segment sum (\(String(format: "%.1f", sumSegmentDurations))s) — ratio=\(String(format: "%.2f", ratio))"
        )
    }
}
AppLog.audio.info("Transcription validation PASSED for \(id.uuidString.prefix(8))")
```

- [ ] **Step 2: Also remove modelContext save from transcription error path**

Replace lines 222-235 in `transcribeSingleFile`. The catch block currently sets `item.status = .failed` and calls `try? modelContext.save()`. Remove the save — the caller handles status:

```swift
// Replace lines 222-235 with:

} catch {
    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    AppLog.provider.error("ContentExtraction: transcription failed for item \(item.id): \(msg)")
    // Post error details so KnowledgeDetailView can show them
    NotificationCenter.default.post(
        name: .transcriptionFailed, object: item.id.uuidString,
        userInfo: ["error": msg])
    if let fallback = loadExistingTranscriptText(for: item.id) {
        return fallback
    }
    return nil
}
```

- [ ] **Step 3: Also remove the save after successful transcription**

Replace lines 214-216 in `transcribeSingleFile`. The engine ID save should happen in ContentPipelineService, not here:

```swift
// Replace lines 214-216 with:

item.transcriptionEngineId = resolvedEngineId(engine)
// Status is set by ContentPipelineService after this method returns
```

And remove the `try modelContext.save()` at line 216 and the `do { try modelContext.save() }` — the method already doesn't save on success path, verify the `try modelContext.save()` at line 216 is actually there. Let me check — reading the code again, line 216 says `try modelContext.save()`. Remove it and the `do {` at line 214... wait, there's no `do {` block. Let me re-read:

The code at 212-218 is:
```swift
try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: item.id)

item.status = .transcribed
item.transcriptionEngineId = resolvedEngineId(engine)
try modelContext.save()
```

Replace with:
```swift
try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: item.id)

item.transcriptionEngineId = resolvedEngineId(engine)
// Status transitions and save are owned by ContentPipelineService
```

- [ ] **Step 4: Fix force-unwrap in resolveTranscriptionEngine**

Replace lines 155-162. The force-unwrap at line 162 is safe today (guard checks nil), but making it explicit prevents future bugs:

```swift
// Replace lines 155-162 with:

let canUseRemoteWhisper: Bool = {
    guard let config, let baseURL = config.baseURL else { return false }
    let supportsTranscription = AIConfigService.shared.supportsAudioTranscription(for: config.providerConfigId)
    let typeSupports = AIConfigService.shared.supportsAudioTranscription(for: config.typeRaw)
    return settings.useRemoteWhisper && (supportsTranscription || typeSupports)
}()

if canUseRemoteWhisper, let config, let baseURL = config.baseURL {
    var apiKey = ""
    if let keyId = config.apiKeyKeychainIdentifier {
        apiKey = (try? SecureKeyStore().loadAPIKey(for: keyId)) ?? ""
    }
    return RemoteTranscriptionEngine(baseURL: baseURL, apiKey: apiKey)
}
```

- [ ] **Step 5: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add wawa-note/Domain/Services/ContentExtractionService.swift
git commit -m "fix: remove ContentExtractionService ModelContext saves, fix force-unwrap

Two issues: (1) extractTextFromAudio saved item status on its own
ModelContext, racing with ContentPipelineService saves on a different
context. Remove all saves — the pipeline caller owns status transitions.
(2) resolveTranscriptionEngine used `config.baseURL!` force-unwrap.
Bind to a local let in the guard clause instead.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: AppleSpeechTranscriptionEngine — cloud fallback timeout + usedCloudFallback visibility

**Files:**
- Modify: `wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift:73,405-435`

**Interfaces:**
- Consumes: `SFSpeechRecognizer.recognitionTask(with:resultHandler:)`
- Produces: `transcribeDirect(url:recognizer:meetingId:) -> Transcript` (unchanged signature)

**Problem 1:** Cloud fallback recognition has no timeout. If Apple's cloud service hangs, the user waits forever with no cancel option.

**Problem 2:** `var usedCloudFallback = false` at line 73 is a public `var`. Should be `private(set)` — only the engine should set it.

- [ ] **Step 1: Change usedCloudFallback visibility**

Replace line 73:
```swift
// Replace:
var usedCloudFallback = false
// With:
private(set) var usedCloudFallback = false
```

- [ ] **Step 2: Add timeout to cloud fallback recognition task**

In `transcribeDirect`, after the cloud request is created (after line 413), add a timeout work item identical to the one used for the on-device path:

Replace the cloud fallback block (lines 405-435) — specifically add timeout handling around the cloudTask:

```swift
// Replace lines 405-435 with:

if nsError.domain.contains("AssistantError") {
    hasResumed = true
    AppLog.transcription.warning("Local recognizer rejected audio, falling back to cloud recognition")
    let cloudRequest = SFSpeechURLRecognitionRequest(url: recognitionURL)
    cloudRequest.shouldReportPartialResults = false
    cloudRequest.addsPunctuation = true
    cloudRequest.requiresOnDeviceRecognition = false
    if let ctx = self.buildContextualTerms() {
        cloudRequest.contextualStrings = ctx
    }

    var cloudHasResumed = false
    let cloudTimeout = DispatchWorkItem {
        guard !cloudHasResumed else { return }
        cloudHasResumed = true
        cloudTask?.cancel()
        continuation.resume(throwing: TranscriptionError.recognitionFailed("Cloud recognition timed out after 120s"))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: cloudTimeout)

    let cloudTask = recognizer.recognitionTask(with: cloudRequest) { cloudResult, cloudError in
        guard !cloudHasResumed else { return }
        if let cloudError {
            cloudHasResumed = true
            cloudTimeout.cancel()
            let cloudNSError = cloudError as NSError
            AppLog.transcription.error("Cloud fallback also failed: \(cloudNSError.domain)/\(cloudNSError.code)")
            continuation.resume(
                throwing: TranscriptionError.recognitionFailed(
                    "\(cloudNSError.domain)/\(cloudNSError.code): \(cloudError.localizedDescription)"))
            return
        }
        guard let cloudResult = cloudResult, cloudResult.isFinal else { return }
        cloudHasResumed = true
        cloudTimeout.cancel()
        self.usedCloudFallback = true
        NotificationCenter.default.post(
            name: .transcriptEngineDidChange,
            object: nil,
            userInfo: ["engineId": "apple-cloud", "label": "Apple Cloud"])
        let transcript = self.buildTranscript(from: cloudResult, recognizer: recognizer, meetingId: meetingId)
        AppLog.transcription.info("Cloud fallback succeeded: \(transcript.segments.count) segments")
        continuation.resume(returning: transcript)
    }
    self.activeRecognitionTask = cloudTask
    return
}
```

Note: `cloudTask` is now declared as `let cloudTask` (local) and assigned to `self.activeRecognitionTask` at the end, matching the existing pattern where `recognitionTask` is assigned to `self.activeRecognitionTask` at line 489. The `cloudTimeout` captures `cloudTask` — this works because `cloudTask` is initialized before the timeout work item is dispatched (compile-time guarantee). However, since capturing a local before it's initialized is a compiler error, restructure slightly:

Actually, the timeout needs to cancel `cloudTask`, but `cloudTask` is the result of `recognizer.recognitionTask(with:)`. The simplest approach: store the task in a variable that the timeout can access. Since `DispatchWorkItem` captures by reference, we need:

```swift
var cloudTask: SFSpeechRecognitionTask?
let cloudTimeout = DispatchWorkItem {
    guard !cloudHasResumed else { return }
    cloudHasResumed = true
    cloudTask?.cancel()
    continuation.resume(throwing: TranscriptionError.recognitionFailed("Cloud recognition timed out after 120s"))
}
DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: cloudTimeout)

cloudTask = recognizer.recognitionTask(with: cloudRequest) { ... }
self.activeRecognitionTask = cloudTask
```

This is the same pattern used for the on-device path (lines 376-382 + 489).

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Transcription/AppleSpeechTranscriptionEngine.swift
git commit -m "fix: add timeout to cloud fallback, make usedCloudFallback private(set)

Cloud fallback (AssistantError 1101/1107) had no timeout protection.
If Apple's cloud recognition hangs, the user is stuck forever.
Add 120s DispatchWorkItem timeout matching the on-device path.
Also change usedCloudFallback from public var to private(set) var.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: RecordingCoordinator — fix stale processingQueue capture in cleanupOrphanedRecordings

**Files:**
- Modify: `wawa-note/Connectivity/RecordingCoordinator.swift:806-816`

**Interfaces:**
- Consumes: `processingQueue: ProcessingQueueService?` (var, set after init)
- Produces: `cleanupOrphanedRecordings()` (unchanged signature)

**Problem:** `cleanupOrphanedRecordings()` runs during `init()`. The `processingQueue` is injected later via property assignment. When broken M4A files are repaired, they're re-enqueued via `capturedQueue` which is `nil` at init time — the items never enter the pipeline.

- [ ] **Step 1: Replace captured stale reference with dynamic access**

Replace lines 806-816. Instead of capturing `processingQueue` at Task creation time (when it's nil), use `self.processingQueue` inside the Task body:

```swift
// Replace lines 806-816 with:

if let manifest = try? store.readRecordingManifest(for: item.id) {
    let itemId = item.id
    Task { @MainActor [weak self] in
        let ok = await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)
        if ok {
            AppLog.audio.info("Repaired broken M4A for item \(itemId.uuidString.prefix(8))")
            // Use current processingQueue at execution time, not capture time
            if let queue = self?.processingQueue {
                queue.enqueue(itemID: itemId, trigger: .backgroundBackfill)
            } else if let pipeline = self?.contentPipeline {
                pipeline.process(itemId, using: self?.modelContext ?? ModelContext(self?.modelContainer ?? ModelContainer()))
            }
        } else {
            AppLog.audio.error("Failed to repair broken M4A for item \(itemId.uuidString.prefix(8))")
        }
    }
}
```

Wait — `cleanupOrphanedRecordings` is called synchronously on `init`. We can't use `await` in a sync function. But the existing code already uses `Task { @MainActor in }` so it's async. The issue is just the capture. Let me look at the exact code again:

Lines 806-816:
```swift
if let manifest = try? store.readRecordingManifest(for: item.id) {
    let itemId = item.id
    let capturedQueue = processingQueue
    Task { @MainActor in
        let ok = await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)
        if ok {
            AppLog.audio.info("Repaired broken M4A for item \(itemId.uuidString.prefix(8))")
            capturedQueue?.enqueue(itemID: itemId, trigger: .backgroundBackfill)
        } else {
            AppLog.audio.error("Failed to repair broken M4A for item \(itemId.uuidString.prefix(8))")
        }
    }
}
```

Fix: Capture `self` weakly and access `processingQueue` dynamically:

```swift
if let manifest = try? store.readRecordingManifest(for: item.id) {
    let itemId = item.id
    Task { @MainActor [weak self] in
        let ok = await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)
        if ok {
            AppLog.audio.info("Repaired broken M4A for item \(itemId.uuidString.prefix(8))")
            // Access processingQueue at execution time (not init-time capture)
            if let queue = self?.processingQueue {
                queue.enqueue(itemID: itemId, trigger: .backgroundBackfill)
            } else if let pipeline = self?.contentPipeline {
                pipeline.process(itemId, using: self?.modelContext ?? /* fallback context unavailable in weak self */)
            }
        } else {
            AppLog.audio.error("Failed to repair broken M4A for item \(itemId.uuidString.prefix(8))")
        }
    }
}
```

Actually, `modelContext` requires a `ModelContainer` to construct. Since `cleanupOrphanedRecordings` already has access to `modelContext` (it's an instance property), we can capture it strongly (it's a value type, copied):

```swift
if let manifest = try? store.readRecordingManifest(for: item.id) {
    let itemId = item.id
    let context = self.modelContext  // value type, safe to capture
    Task { @MainActor [weak self] in
        let ok = await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)
        if ok {
            AppLog.audio.info("Repaired broken M4A for item \(itemId.uuidString.prefix(8))")
            if let queue = self?.processingQueue {
                queue.enqueue(itemID: itemId, trigger: .backgroundBackfill)
            } else if let pipeline = self?.contentPipeline {
                pipeline.process(itemId, using: context)
            }
        } else {
            AppLog.audio.error("Failed to repair broken M4A for item \(itemId.uuidString.prefix(8))")
        }
    }
}
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Connectivity/RecordingCoordinator.swift
git commit -m "fix: use dynamic processingQueue access instead of stale init-time capture

cleanupOrphanedRecordings runs during init() when processingQueue is
still nil. The captured `let capturedQueue = processingQueue` was always
nil, so crash-recovered items with repaired M4A files never entered
the pipeline. Switch to `self?.processingQueue` at Task execution time.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: ShareViewController — prevent double complete()

**Files:**
- Modify: `wawa-note-share/ShareViewController.swift:93-131,181-183`

**Interfaces:**
- Consumes: `extensionContext?.completeRequest(returningItems:)`
- Produces: `complete()` (unchanged signature, now idempotent)

**Problem:** `complete()` can be called from both `group.notify` (line 107-110) and `viewDidAppear` (line 25-27). Calling `extensionContext?.completeRequest()` twice causes system warnings and potential file loss.

- [ ] **Step 1: Add completed flag to guard complete()**

Add a `hasCompleted` boolean flag and guard `complete()` against re-entry:

At the class level (after line 13):
```swift
// Add after `private var hasErrors = false`:
private var hasCompleted = false
```

In `complete()` (line 181-183), add the guard:
```swift
private func complete() {
    guard !hasCompleted else { return }
    hasCompleted = true
    extensionContext?.completeRequest(returningItems: nil)
}
```

- [ ] **Step 2: Also guard the deadline timeout path**

The deadline path (lines 114-130) also calls `complete()`. No change needed — the guard in `complete()` handles it.

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note-share" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note-share/ShareViewController.swift
git commit -m "fix: prevent double completeRequest in ShareViewController

complete() could be called from both group.notify and viewDidAppear
paths. Calling extensionContext?.completeRequest() twice causes system
warnings. Add hasCompleted guard to make complete() idempotent.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: ContentPipelineService — retry feedback + item existence check

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift:395-403,3097-3103`

**Interfaces:**
- Consumes: `AgentLoop.runAutonomous(task:systemPrompt:tools:provider:maxIterations:)`
- Consumes: `KnowledgeItemService.fetchItem(id:)`
- Produces: `process(_:using:forceReanalysis:extractionOnly:)` (unchanged signature)

**Problem 1:** Retry gives the agent the same system prompt and tool set. Only the task description mentions "previous attempt failed." The agent repeats the same mistakes.

**Problem 2:** `ProcessingQueueService.processNext()` calls `pipeline.processEntry()` without checking if the KnowledgeItem still exists. Deleted items silently fail.

- [ ] **Step 1: Enrich retry system prompt with last error**

Replace lines 397-403 in `process()`. The retry task description currently is:
```swift
task: attemptCount == 1
    ? taskDescription
    : "Previous attempt failed. Error: \(lastError ?? "unknown"). Try a different strategy — use different tools, chunk differently, or simplify.",
```

Enrich it to include specific guidance based on the error:
```swift
let retryTaskDescription: String = {
    guard attemptCount > 1, let error = lastError else { return taskDescription }
    return """
        PREVIOUS ATTEMPT FAILED.
        Error: \(error)
        
        ADJUST YOUR STRATEGY:
        - Use a different tool first (try run_command extract before write_analysis).
        - If the content is large, process it in smaller parts.
        - If the content is short, use write_analysis directly.
        - If the tool returned an error, try a different approach to the same goal.
        - If write_analysis validation failed, check the schema requirements.
        
        Original task:
        \(taskDescription)
        """
}()
```

Then use `retryTaskDescription` in the `loop.runAutonomous()` call:
```swift
let stream = loop.runAutonomous(
    task: retryTaskDescription,
    systemPrompt: systemPrompt,
    tools: tools,
    provider: provider,
    maxIterations: iterationBudget
)
```

- [ ] **Step 2: Add item existence check before processing in ProcessingQueueService**

In `processNext()` (around line 3097), add a check before dispatching to the pipeline. The method currently calls:
```swift
await pipeline.processEntry(
    itemID: itemID,
    projectID: next.projectID
)
```

Add a pre-check:
```swift
// Verify the item still exists before processing
let itemExists: Bool = {
    let ctx = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == itemID })
    descriptor.fetchLimit = 1
    return (try? ctx.fetch(descriptor).first) != nil
}()
guard itemExists else {
    AppLog.warn("pipeline", "Item \(itemID.uuidString.prefix(8)) no longer exists — removing from queue")
    await MainActor.run { [weak self] in
        self?.finishJob(entryID, failed: true, error: "Item deleted before processing")
    }
    return
}
```

Wait — `ProcessingQueueService` doesn't have a `modelContainer` property. Let me check what it has access to. Looking at the code, `ContentPipelineService` has `modelContainer`. But `ProcessingQueueService` is a separate class. 

Actually, `processEntry` in `ContentPipelineService` already handles missing items — it logs an error. The issue is that the queue marks the job as "done" when the item was never processed. Let me check if `processEntry` returns anything useful. Looking at the code (lines 623-646):

```swift
func processEntry(itemID: UUID, projectID: UUID? = nil, using modelContext: ModelContext? = nil) async {
    // ...
    process(itemID, using: ctx)
    // ...
}
```

And `process()` checks item existence at line 190:
```swift
guard let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) else {
    AppLog.provider.error("ContentPipeline: item \(itemID) not found in store, aborting")
    return
}
```

So the pipeline already handles it correctly — the item is skipped. But the queue marks it as "done" because `processEntry` completes without throwing. The real fix is to make `finishJob` aware of this silent-failure case.

Simpler approach: Since `ContentPipelineService.process()` already handles missing items (returns early), and the queue's `finishJob` marks it as "done", the outcome is: queue entry is removed, no error, no retry. This is actually correct behavior — the item was deleted, don't retry it. The only issue is that `finishJob` logs "Processing complete" when it was actually a no-op.

Better fix: don't check in the queue. Instead, have `processEntry` throw when the item doesn't exist:

Actually, the simplest correct fix: `process()` at line 190 already returns early when the item doesn't exist. But it also fires the pipelineCompleted notification (line 184-186 via defer). The queue's `processEntry` waits on that notification. So the flow is: item deleted → process() exits early → defer fires .pipelineCompleted → queue marks as "done". This is actually correct! The item was deleted, so "done" (skip it) is the right outcome.

Let me revise the task — the item existence check is handled, just the retry prompt is the real P2 issue. I'll remove step 2 from this task and make it only about the retry prompt.

Wait no, let me re-read the problem. The user's concern was "ProcessingQueue doesn't verify item exists before processing." If the item was deleted, the queue still dispatches a full pipeline run. The pipeline discovers the item is gone and returns early. Meanwhile, the queue held a slot (maxConcurrentJobs = 2) and spent time. Minor inefficiency, not a bug. Let me keep the fix simple — just the retry prompt improvement.

- [ ] **Step 1 (only step): Enrich retry system prompt with last error**

Replace the retry task description at lines 397-403:

```swift
// Find lines 395-405 and replace:
let retryTaskDescription: String
if attemptCount == 1 {
    retryTaskDescription = taskDescription
} else {
    retryTaskDescription = """
        PREVIOUS ATTEMPT FAILED.
        Error: \(lastError ?? "unknown")
        
        ADJUST YOUR STRATEGY:
        - If the error mentions schema validation, check write_analysis required fields.
        - If a tool returned an error, try a different tool for the same goal.
        - If the content is large, process it in smaller parts via run_command.
        - If stuck, start with extract and describe what you see before analyzing.
        
        Original task:
        \(taskDescription)
        """
}

let stream = loop.runAutonomous(
    task: retryTaskDescription,
    systemPrompt: systemPrompt,
    ...
)
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift
git commit -m "fix: enrich retry prompt with specific error and strategy guidance

The retry loop gave the agent the same system prompt and only a generic
'previous attempt failed' message. The agent would repeat the same
mistakes. Now the retry task description includes the specific error
and concrete strategy adjustments (try different tools, chunk content,
check schema requirements).

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: RemoteTranscriptionEngine — detect corrupted chunks before retry

**Files:**
- Modify: `wawa-note/Transcription/RemoteTranscriptionEngine.swift:149-276`

**Interfaces:**
- Consumes: `transcribeSingle(url:prompt:meetingId:) -> Transcript`
- Produces: same (unchanged signature)

**Problem:** For each chunk, the retry loop tries 3 times with exponential backoff. If the WAV file is corrupted (0 bytes, invalid header), all 3 attempts fail with HTTP 400. This wastes API quota and 6+ seconds per chunk.

- [ ] **Step 1: Add pre-flight audio validation**

In `transcribeSingle`, before the retry loop (before line 166), add a quick audio file validation:

```swift
// Add after line 165 (let isCompressed = ...) and before the for loop:

// Pre-flight: validate audio file before sending to API.
// Corrupted files fail fast instead of burning retry attempts.
let audioData: Data
do {
    audioData = try Data(contentsOf: url)
} catch {
    throw TranscriptionError.recognitionFailed("Cannot read audio file: \(error.localizedDescription)")
}
guard !audioData.isEmpty else {
    throw TranscriptionError.recognitionFailed("Audio file is empty")
}
// WAV files must have a valid RIFF header
if url.pathExtension.lowercased() == "wav" {
    guard audioData.count >= 44 else {
        throw TranscriptionError.recognitionFailed("WAV file too small (\(audioData.count) bytes) — minimum 44 bytes for header")
    }
    let riffHeader = String(data: audioData.prefix(4), encoding: .ascii)
    guard riffHeader == "RIFF" else {
        throw TranscriptionError.recognitionFailed("WAV file missing RIFF header — file is corrupted")
    }
}
// M4A files must have an ftyp atom
if ["m4a", "mp4"].contains(url.pathExtension.lowercased()) {
    guard audioData.count >= 8 else {
        throw TranscriptionError.recognitionFailed("M4A file too small (\(audioData.count) bytes)")
    }
    // Check for ftyp atom at offset 4 (after atom size)
    let ftyp = String(data: audioData.subdata(in: 4..<8), encoding: .ascii)
    guard ftyp == "ftyp" else {
        throw TranscriptionError.recognitionFailed("M4A file missing ftyp atom — file is corrupted")
    }
}
```

- [ ] **Step 2: Move the audio data read to reuse in multipart**

The retry loop currently reads audio data in `buildBodyFile` (line 328: `let audioData = try Data(contentsOf: audioURL)`). Since we already read it in Step 1, pass it instead of re-reading. Modify `buildBodyFile` to accept optional pre-loaded data:

In `transcribeSingle`, change the `buildBodyFile` calls to pass the pre-loaded data:

Actually, keeping the change minimal: just add the pre-flight check and leave `buildBodyFile` reading from disk (the file is small enough, and it's cached by the OS after the first read). The pre-flight throw skips the retry loop entirely for corrupted files.

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Transcription/RemoteTranscriptionEngine.swift
git commit -m "fix: validate audio file before retry loop in RemoteTranscriptionEngine

Corrupted WAV/M4A files burned all 3 retry attempts with HTTP 400,
wasting API quota and time. Add pre-flight validation: check file
readability, minimum size, WAV RIFF header, and M4A ftyp atom.
Corrupted files now fail immediately without API calls.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: AudioFileWriter — write checkpoint synchronously

**Files:**
- Modify: `wawa-note/Audio/AudioFileWriter.swift:187-218`

**Interfaces:**
- Consumes: `FileArtifactStore.atomicWriteWithBackup(data:url:)`
- Produces: `writeCheckpoint(meetingId:segmentIndex:format:)` (unchanged signature)

**Problem:** `writeCheckpoint` dispatches async to the writer's serial queue. If writes are piling up (queueDepth > 5), the checkpoint sits in the queue. On crash, the last persisted checkpoint is stale.

- [ ] **Step 1: Write checkpoint sync on the queue**

Replace `queue.async` with `queue.sync` to guarantee the checkpoint is on disk before `writeCheckpoint` returns:

```swift
// Replace line 188: queue.async { [weak self] in
// With:
queue.sync { [weak self] in
```

And remove `[weak self]` since `sync` doesn't need it (it executes immediately):
```swift
queue.sync {
    let checkpoint: [String: Any] = [
        "meetingId": meetingId.uuidString,
        "segmentIndex": segmentIndex,
        "sampleRate": format.sampleRate,
        "channels": format.channelCount,
        "timestamp": Date().timeIntervalSince1970,
        "fileName": self._currentFileURL?.lastPathComponent ?? "unknown",
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: checkpoint) else {
        AppLog.error("audio", "Checkpoint: failed to serialize checkpoint JSON")
        return
    }
    do {
        try self.fileStore.createConfigsDirectory()
    } catch {
        AppLog.error("audio", "Checkpoint: cannot create configs directory — \(error.localizedDescription)")
        return
    }
    let url = self.fileStore.configsDirectoryURL().appendingPathComponent("recording_checkpoint.json")
    do {
        try self.fileStore.atomicWriteWithBackup(data: data, url: url)
    } catch {
        AppLog.error("audio", "Checkpoint: write failed — \(error.localizedDescription)")
    }
}
```

Note: With `queue.sync`, the `[weak self]` is unnecessary — the closure executes inline and won't outlive the caller. Use direct `self.` access.

- [ ] **Step 2: Verify no deadlock**

The caller `writeCheckpoint` is called from `AudioCaptureService`, which does NOT hold the writer's queue lock. It's called from the audio tap callback thread. The `queue.sync` will block the caller briefly (a few ms for the file write) but won't deadlock because:
- caller is NOT on `queue`
- `queue` operations only nest via `queue.async { queue.sync {} }` which is fine

Verify by checking the call site in AudioCaptureService:
The call is `writer.writeCheckpoint(meetingId:segmentIndex:format:)` — this is called from the capture service's observation timer, NOT from within a `queue.async/sync` block.

- [ ] **Step 3: Build verification**

Run: `xcodebuild -project wawa-note.xcodeproj -scheme "wawa-note" -destination "platform=iOS Simulator,name=iPhone 14 Plus" build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Audio/AudioFileWriter.swift
git commit -m "fix: write crash checkpoint synchronously instead of async

writeCheckpoint used queue.async, so the checkpoint could sit in the
queue behind pending writes. On crash, the last checkpoint on disk was
stale (missing recent segments). Switch to queue.sync — the caller is
not on the writer's queue, so no deadlock risk. Checkpoint is now on
disk before writeCheckpoint returns.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: ContentPipelineService.swift split (DEFERRED)

**Files:**
- This task is deferred pending architecture discussion.

**Goal:** Split `ContentPipelineService.swift` (3440 lines) into focused files.

**Proposed split (NOT IMPLEMENTED — requires approval):**
- `ContentPipelineService.swift` — keep only the pipeline flow (lines 1-666)
- `FrameworkService.swift` — extract frameworks + validation (lines 736-1300)
- `ProjectHealthEngine.swift` — extract health computation (lines 1304-1383)
- `PromptStore.swift` — extract prompt management (lines 1450-1600)
- `AgentMemoryStore.swift` — extract memory store (lines 1630-1736)
- `OutputBlocks.swift` — extract output blocks + content parser (lines 1774-2050)
- `ProcessingQueueService.swift` — already extracted (lines 2979+)
- `PipelineStore.swift` — already in same file, could be separate

This task spans 8+ new files and requires `project.pbxproj` additions. Deferred until the P0-P2 fixes are in.

---
