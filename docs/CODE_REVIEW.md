# Wawa Note — Code Review

**Reviewed:** 2026-06-10  
**Reviewer:** GitHub Copilot (Claude Sonnet 4.6)  
**Scope:** All 182 Swift source files + Share Extension  
**Status:** Read-only review — no modifications made

---

## Summary

The codebase is large (~182 Swift files), architecturally coherent, and follows the stated design rules fairly well. Swift Concurrency is used consistently; the protocol-first provider abstraction is clean; SwiftData models are properly structured. However, there are several critical bugs — notably broken tool calling in the Anthropic provider — plus a number of significant logic errors, memory issues, and data-safety gaps.

Findings are grouped by severity:

| Severity | Count |
|---|---|
| 🔴 Critical | 7 |
| 🟠 Major | 14 |
| 🟡 Moderate | 11 |
| 🔵 Minor | 8 |

---

## 🔴 Critical

### C-1 — Anthropic tool_use blocks are malformed
**File:** `Providers/AnthropicProvider.swift` (~line 212–225)

When serializing assistant messages that contain tool calls for the Anthropic API, the code builds a "tool_use" content block using the wrong structure:

```swift
// ACTUAL (wrong)
blocks.append(AnthropicRequest.Message.ContentBlock(
    type: "tool_use",
    text: "id:\(tc.id) name:\(tc.name) args:\(tc.arguments)"
))
```

The Anthropic Messages API requires `tool_use` blocks to carry **structured** JSON fields (`id`, `name`, `input` as an object), not a `text` field with concatenated strings. `ContentBlock` only has a `text: String?` field — the `id`, `name`, and `input` fields required by the API are completely absent from the struct. Similarly, tool results are wrapped as plain user messages (`"[Tool result]: ..."`) instead of proper `tool_result` content blocks.

**Consequence:** Anthropic tool calling is entirely broken. Every agentic loop iteration using an Anthropic provider will fail or produce garbage because the conversation history sent to the API is structurally invalid.

---

### C-2 — GeminiProvider advertises tool calling but never serializes tools
**File:** `Providers/GeminiProvider.swift`

`capabilities.supportsToolCalling = true` is set in the provider, but `GeminiRequest` has no field for tool definitions. When `AgentLoop` sends a request with tool definitions to a Gemini provider, the tools are silently dropped. The model then responds without tool calls, and the agent loop's fallback message ("You must use the run_command tool…") triggers an infinite push-pull up to `maxIterations`, consuming the full token budget.

---

### C-3 — CLLocationManager delegate can be prematurely deallocated
**File:** `ContextCapture/LocationContextSensor.swift` (~line 38–75)

```swift
func capture() async throws -> [CapturedAnnotation] {
    return try await withCheckedThrowingContinuation { continuation in
        let delegate = LocationDelegate()      // strong reference only here
        manager.delegate = delegate            // CLLocationManager holds WEAK
        ...
        manager.requestLocation()
    }
}
```

`CLLocationManager` holds its delegate via a **weak** reference. The only strong reference to `delegate` is the local constant inside the continuation closure. When the timeout fires first (via `DispatchWorkItem`) and resumes the continuation, the closure ends, the strong reference to `delegate` drops to zero, and `delegate` is deallocated. If the location manager's callback fires after the timeout, the delegate is nil and the callback silently fails — this is safe for the current logic. However, the actual crash risk is different: the `delegate.onResult = { location, placemark, error in ... }` closure captures `continuation`. If the `CLLocationManager` fires a callback after the continuation has been resumed (and therefore freed), the closure will attempt to call `continuation.resume(...)` on an invalid continuation, which triggers a crash.

The `guard !resumed else { return }` guard prevents a double-resume, but `resumed` is a stack variable captured by the closure and is NOT protected by a mutex. If both the timeout and the location callback fire concurrently on different queues, `resumed` can be read `false` by both before either sets it to `true`.

---

### C-4 — AgentLoop forces tool usage on final answer, corrupting conversation history
**File:** `Domain/Agent/AgentLoop.swift` (~line 225–237)

```swift
if iteration + 1 < iterations {
    messages.append(ChatMessage(conversationId: UUID(), role: .user,
        content: "You must use the run_command tool to execute actions. Do not just describe..."))
    continue
}
```

This synthetic "user" message is appended to the `messages` array, which is also the conversation history written to disk by `ChatService.appendMessage`. When a user asks a simple factual question (e.g. "How many items are in my inbox?"), the agent can answer without tools on iteration 0. This synthetic message is then injected and persisted to the chat conversation as if the user typed it. The next time the user opens the conversation, the message is visible. This is a data integrity bug that also makes the agent antagonistic.

---

### C-5 — `ChatService.saveMessages` / `saveAllConversations` writes without `.atomic` option
**File:** `Domain/Services/ChatService.swift` (~line 107, 129, 141)

```swift
private func saveAllConversations(_ conversations: [ChatConversation]) throws {
    let data = try JSONEncoder().encode(conversations)
    try data.write(to: baseURL.appendingPathComponent("index.json"))   // no .atomic
}
```

Without `.atomicWrite`, the JSON file is written in-place. If the app is backgrounded or killed mid-write, the file will be partially written and corrupt. On the next launch, `JSONDecoder().decode([ChatConversation].self, from: data)` will throw and all conversations will appear empty. Should use `data.write(to:options: .atomicWrite)`.

---

### C-6 — `WawaNoteApp.init` discards `NotificationCenter` observer tokens
**File:** `App/WawaNoteApp.swift` (~line 82–115)

```swift
NotificationCenter.default.addObserver(
    forName: UIApplication.willEnterForegroundNotification,
    object: nil,
    queue: .main
) { _ in
    coordinator.onAppForeground()
}
```

The block-based `addObserver(forName:object:queue:using:)` overload returns an opaque `NSObjectProtocol` observer token that **must** be retained and eventually removed. The returned token is silently discarded (`_ = ...` is not even written). On iOS, this means the observation registers but the notification center holds the only strong reference — in practice, the observation block will be kept alive indefinitely (which is probably the intent for a root app), but it is not officially guaranteed. Apple's documentation explicitly states the returned observer must be stored and removed with `removeObserver(_:)`. Four separate registrations share this problem.

---

### C-7 — `FileArtifactStore.init` force-unwraps `urls(for:)` result
**File:** `Storage/FileArtifactStore.swift` (~line 28)

```swift
self.baseURL = fileManager
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)
    .first!          // ← crash if empty
    .appendingPathComponent("Meetings", isDirectory: true)
```

`FileManager.urls(for:in:)` can theoretically return an empty array (e.g., sandboxed environment misconfiguration, very early boot). The force-unwrap will crash the app. Should use `guard let` and fall back to a known safe path.

---

## 🟠 Major

### M-1 — `OpenAICompatibleProvider`: dead `ChatCompletionRequest` struct and `buildContent()` function
**File:** `Providers/OpenAICompatibleProvider.swift`

A full private `ChatCompletionRequest: Encodable` struct is defined but **never used**. The `send()` method builds the request body using a `[String: Any]` dictionary and `JSONSerialization.data(withJSONObject:)` instead. There is also a private `buildContent(from:)` function that is never called. This dead code is a maintenance trap — any developer reading the file may assume the Codable path is active and make changes there, while the real logic is elsewhere.

---

### M-2 — `ProviderAdapter.normalizeJSON` silently wraps failed JSON in a fallback object
**File:** `Providers/ProviderAdapter.swift` (~line 132–140)

When all JSON extraction attempts fail, the fallback is:

```swift
return "{\"raw_text\": \"\(escaped)\"}"
```

This returns a valid JSON object with a single `raw_text` field. Callers that then try to `JSONDecoder().decode(AnalysisResponse.self, from:)` this data will receive a zero-field analysis (all optional fields nil). The pipeline then stores this empty `MeetingAnalysis` with an empty summary, marking the item as `.analyzed`. The user sees the item as processed when it actually failed. Should throw instead of wrapping.

---

### M-3 — `AnarlogSyncService.scanAndImport()` increments import counter but never actually imports
**File:** `Ecosystem/Anarlog/AnarlogSyncService.swift` (~line 105–115)

```swift
// Queue import — the caller provides ModelContext
// For now, we just track what should be imported
newImports += 1
logger.info("Discovered new anarlog file: \(filename)")
```

The function increments `importedCount` and sets `lastSyncDate` but doesn't import anything — the comment "for now" has persisted into production code. The `hasWatchedFolder` check and the initial scan triggered in `WawaNoteApp.init()` run this function on app launch and report success without actually syncing any files.

---

### M-4 — `BiometricGateService.isEnabled` stored in `UserDefaults`
**File:** `App/WawaNoteApp.swift` (~line 183)

```swift
@Published var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: "face_id_enabled") }
}
```

`UserDefaults` is not protected by the device's Secure Enclave. An attacker with physical access to the device (using tools like iMazing or direct file system access on a jailbroken device) can modify `UserDefaults` to disable Face ID gate before app launch. Security preferences should be stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

---

### M-5 — `EmbeddingService.load()` returns `nil` for all legacy embeddings
**File:** `LocalIntelligence/EmbeddingService.swift` (~line 50–58)

```swift
// Legacy format: plain [Float] — invalidate on model change
if let vector = try? JSONDecoder().decode([Float].self, from: data) {
    AppLog.general.info("Legacy embedding for \(itemId) — will be regenerated")
    return nil  // discards the vector
}
```

The function successfully decodes a valid `[Float]` embedding and then discards it, returning `nil`. Every item with a legacy embedding will trigger a new API call on the next access until the embedding is regenerated. For a user with many items and no ongoing network, this means silently failing all semantic searches. Should check model compatibility and return the vector if compatible.

---

### M-6 — `SemanticSearchService.findRelevant()` hardcodes the embedding model
**File:** `LocalIntelligence/SemanticSearchService.swift` (~line 22)

```swift
let queryVector = try await provider.embed(query, model: "text-embedding-3-small")
```

The model name is hardcoded. If the `EmbeddingService` was initialized with a different model, the stored vectors are in a different embedding space than the query vector. Cosine similarity comparisons between vectors from different embedding models are meaningless. The model should be read from `EmbeddingService`'s configured `embeddingModel`.

---

### M-7 — `ProjectIngestionPipeline.runIngestion()` skips `responseFormat` guard for fix-prompt request
**File:** `Domain/Services/ProjectIngestionPipeline.swift` (~line 155)

```swift
let fixRequest = AIRequest(
    model: model,
    messages: [...],
    responseFormat: .jsonObject   // unconditionally set on retry
)
```

The main request correctly uses `requestParams` which omits temperature for reasoning models. The fix-prompt retry request hard-codes `responseFormat: .jsonObject` without checking `AIConfigService.shared.supportsJSONFormat(for:)`. For reasoning models this will be stripped by `OpenAICompatibleProvider`, but for providers that return an error when unsupported JSON format is requested, the retry will also fail.

---

### M-8 — `ContextWindowManager.deduplicateToolResults()` uses `hashValue` for deduplication
**File:** `Domain/Agent/ContextWindowManager.swift` (~line 88)

```swift
let hash = String(msg.content.hashValue)
if let first = seen[hash] { ... }
seen[hash] = msg.content
```

`String.hashValue` can collide (two different strings can have the same hash). More importantly, it's only stable within a process run; across sessions any reliance on it for identity is wrong. For content equality comparisons, direct string equality (`seen[msg.content]`) is correct and only marginally slower for typical tool output sizes.

---

### M-9 — `AgentLoop.runLoop()` injects internal orchestration messages into user-visible chat history
**File:** `Domain/Agent/AgentLoop.swift` (~line 158–160)

```swift
if wasTruncated {
    adjusted.insert(ChatMessage(conversationId: UUID(), role: .system,
        content: "[SYSTEM NOTE: \(truncatedCount) older messages were truncated...]"), at: 0)
}
```

These synthetic system messages are inserted into `adjusted` (the in-flight messages array) but `messages` is the array that eventually gets written to disk via `chatService.appendMessage`. Because the loop appends to `messages` at the end of each iteration, any internal orchestration messages that are part of `adjusted` can bleed into `messages` through reference aliasing if the caller passes `messages` as `adjusted` (which happens in the non-truncated path). When the chat UI loads history, these technical messages appear as assistant messages.

---

### M-10 — `ChatService.appendMessage()` is not concurrency-safe for rapid sequential calls
**File:** `Domain/Services/ChatService.swift` (~line 75–93)

Although `ChatService` is `@MainActor`, the `appendMessage` pattern is:

1. `var messages = try messages(for: conversationId)` — reads file
2. `messages.append(message)`
3. `try saveMessages(messages, ...)` — writes file

Between steps 1 and 3, another `appendMessage` call on the same `@MainActor` (possible via reentrancy through `await`) could read the same set of messages and overwrite with a different append. In practice, the chat view's streaming flow calls `appendMessage` many times in quick succession via `continuation.yield`. Since `@MainActor` prevents true concurrency but allows reentrancy at `await` points, two `appendMessage` calls that interleave could result in message loss.

---

### M-11 — `TrashService.isTrash()` uses fragile identity check
**File:** `Domain/Services/TrashService.swift` (~line 33)

```swift
func isTrash(_ folder: Folder) -> Bool {
    folder.name == "Trash" && folder.iconName == "trash"
}
```

If a user renames the Trash folder (e.g. "Recycle Bin") or changes its icon via any editing path, all trash-related operations silently stop working: `moveToTrash` will create a new folder named "Trash" instead of using the existing one, `itemsInTrash` will show no items, and `emptyTrash` will clear an empty set. Trash should be identified by a stable boolean column or enum value on the `Folder` model, not by display name + icon.

---

### M-12 — `ProjectService.deleteProject()` deletes items' inter-item edges twice
**File:** `Domain/Services/ProjectService.swift` (~line 106–116)

```swift
for iid in itemIDs {
    let out = try context.fetch(...)
    for e in out { context.delete(e) }
    let incoming = try context.fetch(...)
    for e in incoming { context.delete(e) }
}
```

This is called after the loop that also deletes `edgesOut` and `edgesIn` for the project itself (lines ~101–107). Items in the project can have edges pointing to each other or to the project. The first loop deletes project-level edges (where `fromID == pid` or `toID == pid`). The second loop re-fetches edges where `fromID` or `toID` is an item in the project. These two sets can overlap (e.g. an item-to-project edge will be fetched again). Calling `context.delete` on an already-deleted SwiftData object is a programming error that can cause undefined behaviour or crashes.

---

### M-13 — `RemoteTranscriptionEngine.init()` ignores the `session` parameter
**File:** `Transcription/RemoteTranscriptionEngine.swift` (~line 32–36)

```swift
init(baseURL: URL, apiKey: String = "", session: URLSession = .shared) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 180
    config.timeoutIntervalForResource = 300
    self.session = URLSession(configuration: config)   // ignores parameter
}
```

The `session` parameter is accepted but immediately discarded — a new `URLSession` is always created. This means unit tests that inject a mock session will have no effect. The parameter should either be used or removed.

---

### M-14 — `JSONImporter`: imported item UUID override can cause SwiftData uniqueness collision
**File:** `Ecosystem/Import/Importers/JSONImporter.swift` (~line 64–67)

```swift
if let idStr = imported.item?.id, let uuid = UUID(uuidString: idStr) {
    item.id = uuid
}
```

The importer overwrites the freshly created `KnowledgeItem`'s `UUID` with the one from the JSON file. Because `KnowledgeItem.id` has `@Attribute(.unique)`, importing the same file twice will trigger a SwiftData constraint violation and throw. The error is not caught in `importTextFile` — it propagates up and the item is shown to the user as "failed to import" with no clear reason.

---

## 🟡 Moderate

### MOD-1 — `MarkdownExporter`: YAML frontmatter injection vulnerability
**File:** `Ecosystem/MarkdownExporter.swift` (~line 13)

```swift
md += "title: \"\(item.title)\"\n"
```

If `item.title` contains double quotes or newlines, the YAML frontmatter is syntactically broken. Example: a title of `Meeting "Q4" Results` produces `title: "Meeting "Q4" Results"` — invalid YAML. YAML strings containing special characters should be properly escaped or use block scalars.

---

### MOD-2 — `SearchService.match()`: O(n) string distance calculation per match
**File:** `Domain/Services/SearchService.swift` (~line 58–60)

```swift
let start = text.index(range.lowerBound, offsetBy: -min(20, text.distance(from: text.startIndex, to: range.lowerBound)), limitedBy: text.startIndex) ?? text.startIndex
```

`text.distance(from:to:)` is O(n) for Swift's `String` (Unicode grapheme clusters). This is called for every matched search result on every field for every item. For large transcripts or many items, this becomes a quadratic performance bottleneck. Should use UTF-8 view indices or compute offsets with `String.Encoding.utf8`.

---

### MOD-3 — `ShellInterpreter` is `@MainActor` — all VFS database operations block the main thread
**File:** `Domain/Agent/ShellInterpreter.swift` (entire file)

The entire `ShellInterpreter` enum is `@MainActor`. Every `ls`, `cat`, `find`, and `echo` command calls `KnowledgeItemService`, `ProjectService`, `TaskService`, etc., all of which use `ModelContext.fetch()`. For large databases with many items, these synchronous fetches execute on the main thread and block the UI. The `ShellTool.execute()` is marked `@MainActor` and is called from `AgentLoop.runLoop()`, which runs inside a `Task { }` on the cooperative thread pool but has to hop to the main actor.

---

### MOD-4 — `AIConfigService.shared` is initialized with `fatalError` on any config parse failure
**File:** `Providers/AIConfigService.swift` (~line 63–67)

```swift
} catch {
    AppLog.provider.error("Failed to decode ai_config.json: \(error)")
    fatalError("ai_config.json is invalid: \(error)")
}
```

If `ai_config.json` is accidentally shipped with a syntax error or a new field is introduced without a `Codable` mapping, the app crashes immediately on launch with no recovery path. Since `AIConfigService.shared` is accessed everywhere, this failure mode is total. Should have a safe fallback with defaults.

---

### MOD-5 — `ActiveProviderManager` stores active provider ID in `UserDefaults`
**File:** `Providers/ActiveProviderManager.swift`

The selected AI provider UUID is stored in `UserDefaults`. If the user has multiple provider configurations, this is not a secret. However, on a shared/enterprise device, `UserDefaults` can be read by other apps sharing the same App Group. The design is acceptable for non-sensitive data, but it should be documented.

---

### MOD-6 — `ContentPipelineService.process()`: missing check for `@MainActor` task cancellation
**File:** `Domain/Services/ContentPipelineService.swift`

The pipeline creates `Task { @MainActor in ... }` for each item but only checks `Task.isCancelled` inside `AgentLoop.runLoop`. The outer `ContentPipelineService.process()` function does not check cancellation before starting, meaning a cancelled `ProcessingQueueService` job can still initiate the full AI pipeline before being cancelled inside the loop.

---

### MOD-7 — `WawaNoteApp.init` creates separate `ModelContext` instances for migrations
**File:** `App/WawaNoteApp.swift` (~line 68–71)

```swift
KnowledgeItemService.migrateMeetingToAudio(context: ModelContext(modelContainer))
ProjectService.migrateProjectColors(context: ModelContext(modelContainer))
ProjectService.migrateFieldProvenance(context: ModelContext(modelContainer))
```

Three separate `ModelContext` instances are created and used sequentially. Changes written by one context (e.g., `migrateMeetingToAudio`) are not visible to the next context until saved, and SwiftData's merge policy may behave unexpectedly. All three migrations should use the same `ModelContext` instance, or the shared context from `RecordingCoordinator`.

---

### MOD-8 — `ProjectIngestionPipeline` has no rate limiting or concurrency cap
**File:** `Domain/Services/ProjectIngestionPipeline.swift`

When multiple items are added to a project simultaneously, each triggers an independent `ingest()` call. There is no serialisation, no token-bucket, and no cap on concurrent AI requests. With 10 items added at once, 10 parallel LLM calls will be issued, likely hitting API rate limits (HTTP 429). The `ProviderError.requestFailed(statusCode: 429)` path is handled but only retries are logged — there is no backoff.

---

### MOD-9 — `ContentPipelineService` uses `try?` silently on critical `modelContext.save()`
**File:** `Domain/Services/ContentPipelineService.swift` (multiple locations)

Several `try? modelContext.save()` calls silently swallow save errors. If SwiftData fails to persist a pipeline result, the item will show as "analyzed" in memory but the data is lost on the next launch. Critical saves should propagate errors.

---

### MOD-10 — `ContextWindowManager.autoSummarize()` always uses 40% split regardless of budget
**File:** `Domain/Agent/ContextWindowManager.swift` (~line 105–120)

The function always collapses the oldest 40% of messages into a pseudo-summary, even if the total token count is already below the budget. The guard `totalTokens > summaryAfterTokens` prevents unnecessary compression, but `summaryAfterTokens = 6000` is a fixed constant that doesn't scale with the configured context window (which can be up to 1M tokens for some models). On large-context models, this triggers aggressive pruning that is wasteful.

---

### MOD-11 — `ShareViewController` uses `NSLog` instead of unified logging
**File:** `wawa-note-share/ShareViewController.swift`

The share extension uses `NSLog(...)` throughout, which is synchronous and substantially slower than `OSLog.Logger`. In a share extension, which has a hard 30-second time budget, synchronous I/O in the logging path is an unnecessary risk. Should use `Logger(subsystem:category:)`.

---

## 🔵 Minor

### MIN-1 — `UIApplication.shared.applicationIconBadgeNumber` is deprecated in iOS 17
**File:** `App/WawaNoteApp.swift` (~line 137, 165)

`UIApplication.shared.applicationIconBadgeNumber` was deprecated in iOS 16 and the `set` path is no-op on iOS 17+. Should use `UNUserNotificationCenter.current().setBadgeCount(_:withCompletionHandler:)`.

---

### MIN-2 — `AppLog` event/warn functions fall through to `general` category for unknown categories
**File:** `Utilities/Logging.swift`

`AppLog.event("agent", ...)` and `AppLog.warn("agent", ...)` (called from `AgentLoop`) fall through to `AppLog.general.info(...)` because the `switch category` block only covers `"audio"`, `"transcription"`, `"provider"`, `"storage"`, and `"general"`. The `"agent"` category is written to the file log correctly but uses the wrong OSLog category. An `AppLog.agent` logger should be defined.

---

### MIN-3 — `ProviderAdapter.buildRequest()` hardcodes model names as fallbacks
**File:** `Providers/ProviderAdapter.swift` (~line 78–85)

```swift
case .anthropic:
    return template.model ?? "claude-sonnet-4-6"
case .gemini:
    return template.model ?? "gemini-2.5-flash"
case .openAI, ...:
    return template.model ?? "gpt-5.5"
```

Model names are hardcoded as fallbacks. When these models are deprecated or renamed, the code will send invalid model names to the API, causing HTTP 404 errors with no clear diagnostic message. These fallbacks should be read from `ai_config.json` via `AIConfigService`.

---

### MIN-4 — `PDFImporter.importSourceURL` stores a sandboxed file path
**File:** `Ecosystem/Import/Importers/PDFImporter.swift` (~line 28)

```swift
item.importSourceURL = url.absoluteString
```

The `url` here is an `applicationSupportDirectory` path inside the app sandbox. After an app update or reinstall, sandbox paths change and the stored URL becomes invalid. This is a low-priority issue since `importSourceURL` is metadata, but it could mislead future features that try to re-read from the source.

---

### MIN-5 — `AnarlogSyncService.saveBookmark()` uses `.minimalBookmark`
**File:** `Ecosystem/Anarlog/AnarlogSyncService.swift` (~line 39)

```swift
let bookmark = try url.bookmarkData(
    options: .minimalBookmark,
    ...
)
```

On iOS, `.minimalBookmark` creates a bookmark that does not persist security-scoped access across app launches. The documented approach for security-scoped bookmarks is to omit the options parameter (use `options: []`) or use `options: .withSecurityScope` (macOS only). In practice, `.minimalBookmark` on iOS may work if the user re-grants access each session, but it is not a reliable cross-launch bookmark.

---

### MIN-6 — `EvalSystem`: `EvalCheck.id` computed from `name` only — not unique if same check runs twice
**File:** `Ecosystem/Anarlog/EvalSystem.swift` (~line 25)

```swift
struct EvalCheck: Codable, Identifiable {
    var id: String { name }
```

If the same field is validated twice (e.g. a schema with duplicate field entries), `id` collides and `List(checks, id: \.id)` in SwiftUI would crash with a runtime assertion. This is an edge case but should use a stable `UUID` or index-based ID.

---

### MIN-7 — `ContextWindowManager.prepareMessages()` token estimation uses 4 chars/token globally
**File:** `Domain/Agent/ContextWindowManager.swift` (~line 10)

```swift
private let charsPerToken = 4
```

4 characters per token is a rough average for English prose. For content with high Unicode density (Asian characters, emoji), 1–2 characters per token is more accurate. Under-estimating token counts means the context window budget overruns in practice, potentially triggering API-level "context too long" errors.

---

### MIN-8 — `MarkdownExporter`: seconds-only duration formatting truncates hours
**File:** `Ecosystem/MarkdownExporter.swift` (~line 76)

```swift
private func formatDuration(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    if m >= 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(m)m"
}
```

For durations like 1h 30m 45s, the seconds component is discarded. More importantly, the branch `m >= 60` correctly shows hours and remaining minutes. But the sub-60-minute branch shows only minutes without seconds, so a 59m 59s recording exports as "59m". This is cosmetic but slightly misleading.

---

## Architectural Observations (non-bug)

### A-1 — `AnthropicProvider` does not implement native tool calling at the API level

Even after fixing C-1, the Anthropic Messages API requires dedicated message types for `tool_use` and `tool_result`. The current `AnthropicRequest.Message.ContentBlock` only has `type: String` and `text: String?`. A proper implementation needs separate Encodable structs for text, tool_use, and tool_result content blocks, and the `AnthropicRequest.Message.Content` enum needs a corresponding case.

---

### A-2 — `ContentPipelineService` mixes `@MainActor` isolation with long-running async work

The entire pipeline — including all SwiftData operations, agent iterations, and file I/O — runs on the `@MainActor`. While Swift Concurrency's `await` points yield the actor, the pattern means any synchronous code (DB fetches, manifest reads) directly blocks the main thread. Consider moving the pipeline to a background actor with explicit hops to `@MainActor` only for SwiftData mutations.

---

### A-3 — `ProcessingQueueService` referenced but not found in source tree

`ContentPipelineService` and `WawaNoteApp` both reference `ProcessingQueueService` (seen as a property and environment object), but no `ProcessingQueueService.swift` file exists in the source tree. Either the file is missing from the repository or it is generated/vendored from another location. This makes the `process()` call path from the queue unverifiable.

---

### A-4 — `ChatService` uses file-per-conversation JSON instead of SwiftData

Chat messages are stored as JSON files (`{conversationId}.json`) in the app support directory while all other entities use SwiftData. This inconsistency means chat history cannot be queried with SwiftData predicates, cannot be included in iCloud/backup automatically, and requires manual file management (`deleteConversation` must manually delete the JSON file). Unifying under SwiftData would simplify the architecture.

---

### A-5 — `VFSService` path resolution does linear scan on all projects for every command

**File:** `Domain/Agent/VFSService.swift`

Every `resolve()` call (which happens on every shell command) calls `ProjectService.allProjects()` to find a matching project. For a workspace with 50+ projects, this is a full SwiftData fetch on every `ls`, `cd`, `cat`, and `echo` call. Consider caching the project list within a VFSService instance or using a `@MainActor` dict keyed by slug.

---

### A-6 — Notification names defined in `PostRecordingAutomationService.swift` — misleading location

**File:** `Domain/Services/PostRecordingAutomationService.swift`

`Notification.Name` extensions like `.transcriptReady`, `.pipelineCompleted`, etc. are defined in `PostRecordingAutomationService.swift`. These notifications are now used throughout the app by many services unrelated to post-recording automation. They should live in a dedicated `Notifications.swift` file or in the files that post/observe them.

---

## Test Coverage Notes

- Only `wawa-noteTests/CoreServicesTests.swift` and `wawa-noteTests/AnarlogDocumentTests.swift` exist (27 tests total).
- Critical paths with zero test coverage: `AnthropicProvider.send()`, `AgentLoop.runLoop()`, `VFSService.resolve()`, `ContentPipelineService.process()`, `ShellInterpreter.execute()`, `ProviderRouter.provider(for:)`, `TrashService`, `ChatService`, `SemanticSearchService.findRelevant()`.
- The `EvalSystem` has no tests despite being a validation gate on AI output quality.
- All provider implementations lack integration test stubs or mock providers.

---

*End of review. All findings are read-only observations. No source files were modified.*
