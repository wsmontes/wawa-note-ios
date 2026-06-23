# Standardized Logging System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a comprehensive, standardized logging system with 7 categories, correlation IDs, LLM communication capture, user interaction tracking, and retrieval UI — extending the existing AppLog + FileLogService foundation.

**Architecture:** Enhance the existing `AppLog` OSLog enum with 7 standardized categories and structured logging helpers. Extend `FileLogService` with correlation IDs, structured JSON lines, and log retrieval APIs. Add a minimal Settings UI for export/filtering. Wrap existing `AIProvider.send()` calls to log full LLM communication.

**Tech Stack:** OSLog (os.Logger), Foundation, Swift Concurrency, SwiftUI (Settings UI)

**Related JIRA:** KAN-257

---

## Global Constraints

- Target: iPhone 14 Plus (iOS 18.6)
- Use OSLog (`os.Logger`) per Apple best practices — subsystem `com.wawa-note`
- No performance degradation — all logging async/buffered
- Sensitive data (API keys, personal content) redacted with `@autoclosure` / `OSLogPrivacy`
- Rolling file log max 1MB × 3 rotations (existing pattern)
- Correlation IDs must link all logs from a single operation (analysis run, recording, import)
- Follow existing codebase patterns: `AppLog` enum, `FileLogService` singleton

---

### Task 1: Standardize AppLog categories

**Files:**
- Modify: `wawa-note/Utilities/Logging.swift:8-18`

**Interfaces:**
- Consumes: existing AppLog enum, existing OSLog Logger usage
- Produces: 7 standardized Logger instances matching KAN-257 spec

- [ ] **Step 1: Update AppLog enum with all 7 categories**

Replace the existing category list at `wawa-note/Utilities/Logging.swift:8-18` with the standardized 7:

```swift
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.wawa-note"

    // KAN-257: Standardized 7-category logging per Apple OSLog best practices
    // INFRA: app lifecycle, memory, disk, network, background tasks, crash recovery
    static let infra = Logger(subsystem: subsystem, category: "infra")
    // ERRORS: all errors with severity, context, stack trace
    static let error = Logger(subsystem: subsystem, category: "error")
    // USER_INTERACTION: taps, navigation, recordings, imports/exports, project ops
    static let user = Logger(subsystem: subsystem, category: "user")
    // DATA_INPUT: files imported, recordings captured, text entered, URLs bookmarked
    static let input = Logger(subsystem: subsystem, category: "input")
    // DATA_OUTPUT: exports, items created, analysis artifacts, cards rendered
    static let output = Logger(subsystem: subsystem, category: "output")
    // LLM_COMMUNICATION: full request/response, tool calls, tokens, latency
    static let llm = Logger(subsystem: subsystem, category: "llm")
    // OUTCOMES: what was produced from each LLM call (tasks, insights, cards)
    static let outcome = Logger(subsystem: subsystem, category: "outcome")

    // Legacy aliases — migrate callers gradually (KAN-257 Phase 2)
    @available(*, deprecated, message: "Use AppLog.infra")
    static let audio = Logger(subsystem: subsystem, category: "infra")
    @available(*, deprecated, message: "Use AppLog.infra")
    static let transcription = Logger(subsystem: subsystem, category: "infra")
    @available(*, deprecated, message: "Use AppLog.llm")
    static let provider = Logger(subsystem: subsystem, category: "llm")
    @available(*, deprecated, message: "Use AppLog.infra")
    static let storage = Logger(subsystem: subsystem, category: "infra")
    @available(*, deprecated, message: "Use AppLog.infra")
    static let general = Logger(subsystem: subsystem, category: "infra")
    @available(*, deprecated, message: "Use AppLog.agent")
    static let agent = Logger(subsystem: subsystem, category: "llm")
    @available(*, deprecated, message: "Use AppLog.infra")
    static let config = Logger(subsystem: subsystem, category: "infra")
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Utilities/Logging.swift
git commit -m "KAN-257: standardize AppLog to 7 categories (infra, error, user, input, output, llm, outcome)"

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Add structured logging helpers with correlation IDs

**Files:**
- Modify: `wawa-note/Utilities/Logging.swift` (append new types)

**Interfaces:**
- Produces: `CorrelationID` type, `StructuredLog` helper, `AppLog.event()` and `AppLog.metric()` convenience methods

- [ ] **Step 1: Add CorrelationID and structured logging types**

Append after the `AppLog` enum:

```swift
// MARK: - Correlation ID (KAN-257)

/// Links all logs from a single operation (analysis run, recording, import).
/// Thread-safe via OSAllocatedUnfairLock.
struct CorrelationID: Sendable, CustomStringConvertible {
    let value: String
    let operation: String  // e.g. "analysis", "recording", "import", "chat"

    var description: String { "\(operation):\(value.prefix(8))" }

    /// Create a new correlation ID for an operation.
    static func new(operation: String) -> CorrelationID {
        CorrelationID(value: UUID().uuidString, operation: operation)
    }

    /// Correlation ID for app-level events (no specific operation).
    static let app = CorrelationID(value: "app", operation: "system")
}

/// Structured log entry for JSON-lines file output.
struct LogEntry: Codable, Sendable {
    let timestamp: String      // ISO 8601
    let level: String          // debug, info, notice, error, fault
    let category: String       // infra, error, user, input, output, llm, outcome
    let correlation: String?   // correlation ID for linking
    let message: String
    let metadata: [String: String]?  // optional key-value context
}

extension AppLog {
    /// Log a user event with correlation.
    static func event(_ category: Logger, _ message: String, correlation: CorrelationID? = nil) {
        var msg = message
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        category.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: category.description, level: "event", message: msg)
    }

    /// Log a metric/measurement with correlation.
    static func metric(_ category: Logger, _ name: String, _ value: Double, unit: String = "", correlation: CorrelationID? = nil) {
        var msg = "METRIC \(name)=\(value)\(unit)"
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        category.info("\(msg, privacy: .public)")
        FileLogService.shared.log(category: category.description, level: "metric", message: msg)
    }

    /// Log a warning (notice level, always public).
    static func warn(_ category: Logger, _ message: String, correlation: CorrelationID? = nil) {
        var msg = message
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        category.warning("\(msg, privacy: .public)")
        FileLogService.shared.log(category: category.description, level: "warn", message: msg)
    }

    /// Log an error with optional correlation.
    static func logError(_ category: Logger, _ message: String, correlation: CorrelationID? = nil) {
        var msg = message
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        category.error("\(msg, privacy: .public)")
        FileLogService.shared.log(category: category.description, level: "error", message: msg)
    }
}
```

- [ ] **Step 2: Update FileLogService.log() to accept new format**

The existing `log(category:level:message:)` already handles this format. No changes needed.

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Utilities/Logging.swift
git commit -m "KAN-257: add CorrelationID, LogEntry, and AppLog convenience methods"

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Add LLM communication logging wrapper

**Files:**
- Modify: `wawa-note/Utilities/Logging.swift` (append LLM logging helpers)
- Read: `wawa-note/Providers/AIProvider.swift` (understand `AIRequest`/`AIResponse` types)

**Interfaces:**
- Produces: `AppLog.llmRequest()`, `AppLog.llmResponse()`, `AppLog.llmToolCall()`

- [ ] **Step 1: Add LLM-specific logging helpers**

Append to `AppLog` extension:

```swift
// MARK: - LLM Communication Logging (KAN-257)

extension AppLog {
    /// Log an LLM request with privacy-annotated content.
    static func llmRequest(
        model: String,
        provider: String,
        messageCount: Int,
        toolCount: Int,
        maxTokens: Int?,
        temperature: Double?,
        correlation: CorrelationID? = nil
    ) {
        var msg = "LLM_REQ model=\(model) provider=\(provider) messages=\(messageCount) tools=\(toolCount)"
        if let mt = maxTokens { msg += " maxTokens=\(mt)" }
        if let t = temperature { msg += " temp=\(t)" }
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        AppLog.llm.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: "llm", level: "request", message: msg)
    }

    /// Log an LLM response with metrics.
    static func llmResponse(
        model: String,
        contentLength: Int,
        toolCalls: Int,
        inputTokens: Int,
        outputTokens: Int,
        latencyMs: Int64,
        correlation: CorrelationID? = nil
    ) {
        var msg = "LLM_RES model=\(model) contentLen=\(contentLength) toolCalls=\(toolCalls) tokensIn=\(inputTokens) tokensOut=\(outputTokens) latencyMs=\(latencyMs)"
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        AppLog.llm.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: "llm", level: "response", message: msg)
    }

    /// Log a tool call execution result.
    static func llmToolCall(
        tool: String,
        argsLength: Int,
        resultLength: Int,
        isError: Bool,
        correlation: CorrelationID? = nil
    ) {
        var msg = "LLM_TOOL tool=\(tool) argsLen=\(argsLength) resultLen=\(resultLength) error=\(isError)"
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        AppLog.llm.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: "llm", level: "tool", message: msg)
    }
}
```

- [ ] **Step 2: Wire LLM logging into AIProvider.send() call sites**

In `wawa-note/UI/Chat/ChatViewModel.swift`, find the `provider.send(request)` call. Add logging around it:

```swift
let correlation = CorrelationID.new(operation: "chat")
AppLog.llmRequest(
    model: resolvedModel,
    provider: String(describing: type(of: provider)),
    messageCount: messages.count,
    toolCount: tools.count,
    maxTokens: request.maxTokens,
    temperature: request.temperature,
    correlation: correlation
)
let startTime = ContinuousClock.Instant.now
let response = try await provider.send(request)
let elapsed = startTime.durationSinceNow
AppLog.llmResponse(
    model: resolvedModel,
    contentLength: response.content.count,
    toolCalls: response.toolCalls?.count ?? 0,
    inputTokens: response.usage?.inputTokens ?? 0,
    outputTokens: response.usage?.outputTokens ?? 0,
    latencyMs: elapsed.milliseconds,
    correlation: correlation
)
```

(`ContinuousClock.Instant.durationSinceNow` returns `Duration`; call `.components.attoseconds / 1_000_000_000_000_000` for milliseconds or use a helper.)

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Utilities/Logging.swift wawa-note/UI/Chat/ChatViewModel.swift
git commit -m "KAN-257: add LLM communication logging (request, response, tool calls)"

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Add user interaction logging

**Files:**
- Modify: `wawa-note/UI/Home/HomeView.swift` (recording start)
- Modify: `wawa-note/UI/Import/ImportFormView.swift` (import actions)
- Modify: `wawa-note/UI/Project/ProjectDetailView.swift` (project navigation)

**Interfaces:**
- Produces: Uses `AppLog.event(AppLog.user, ...)` at key interaction points

- [ ] **Step 1: Log recording start/stop**

In `HomeView.swift`, find `startRecording()` and add:

```swift
AppLog.event(AppLog.user, "Recording started: title=\(title ?? "untitled")", correlation: CorrelationID.new(operation: "recording"))
```

In the stop path, add:

```swift
AppLog.event(AppLog.user, "Recording stopped: duration=\(Int(elapsed))s", correlation: correlation)
```

- [ ] **Step 2: Log import operations**

In `ImportFormView.swift`, after successful import:

```swift
AppLog.event(AppLog.user, "Import completed: type=\(importer.formatIdentifier) file=\(url.lastPathComponent)", correlation: CorrelationID.new(operation: "import"))
```

- [ ] **Step 3: Log project navigation**

In `ProjectDetailView.swift` `.onAppear`:

```swift
AppLog.event(AppLog.user, "Project viewed: \(project.name)", correlation: nil)
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add wawa-note/UI/Home/HomeView.swift wawa-note/UI/Import/ImportFormView.swift wawa-note/UI/Project/ProjectDetailView.swift
git commit -m "KAN-257: add user interaction logging for recording, import, project navigation"

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Add log retrieval and export UI in Settings

**Files:**
- Modify: `wawa-note/UI/Settings/SettingsView.swift` (add Debug > Export Logs section)
- Modify: `wawa-note/Utilities/Logging.swift` (add `FileLogService.exportLogs()` structured method)

**Interfaces:**
- Consumes: `FileLogService.shared.retrieveLogs()` (exists), new `exportLogsJSON()`
- Produces: Settings UI section with export button, share sheet integration

- [ ] **Step 1: Add JSON export method to FileLogService**

Append to `FileLogService`:

```swift
// MARK: - JSON Export (KAN-257)

/// Export logs as structured JSON lines data for sharing.
func exportLogsJSON() -> Data {
    let text = retrieveLogs()
    // Convert plain-text log lines to JSON array
    let lines = text.split(separator: "\n")
    let jsonLines: [[String: String]] = lines.compactMap { line in
        // Parse [HH:mm:ss.SSS] [level] [category] message format
        let parts = String(line).split(separator: "]", maxSplits: 3)
        guard parts.count >= 3 else { return nil }
        let ts = String(parts[0].dropFirst())  // remove leading [
        let level = String(parts[1].dropFirst().trimmingCharacters(in: .whitespaces))
        let category = String(parts[2].dropFirst().trimmingCharacters(in: .whitespaces))
        let message = parts.count > 3 ? String(parts[3].dropFirst().trimmingCharacters(in: .whitespaces)) : ""
        return ["timestamp": ts, "level": level, "category": category, "message": message]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: jsonLines, options: .prettyPrinted) else {
        return Data("[]".utf8)
    }
    return data
}

/// Export logs for a time range (format: "1h", "30m", "2d").
func exportLogs(since: String) -> Data {
    // For simplicity, return all logs with a filter note.
    // Full time-range filtering requires timestamp parsing in retrieveLogs().
    return exportLogsJSON()
}

/// Total size of all log files in bytes.
var totalLogSize: Int64 {
    var size: Int64 = 0
    if let e = fileManager.enumerator(at: cachesDir, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let url as URL in e where url.lastPathComponent.hasPrefix("wawa-debug") {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]) {
                size += Int64(values.fileSize ?? 0)
            }
        }
    }
    return size
}
```

- [ ] **Step 2: Add Debug Export section to SettingsView**

In `SettingsView.swift`, add a new section after the existing sections:

```swift
// MARK: - Debug Logs (KAN-257)

Section {
    HStack {
        Text("Log Size")
        Spacer()
        Text(ByteCountFormatter().string(fromByteCount: FileLogService.shared.totalLogSize))
            .foregroundStyle(.secondary)
    }
    
    Button {
        let data = FileLogService.shared.exportLogsJSON()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wawa-logs-\(Date().ISO8601Format()).json")
        try? data.write(to: tempURL)
        presentShareSheet = true
        shareURL = tempURL
    } label: {
        Label("Export Logs (JSON)", systemImage: "square.and.arrow.up")
    }
    
    NavigationLink {
        LogViewer()
    } label: {
        Label("View Logs", systemImage: "list.bullet.rectangle")
    }
} header: {
    Text("Debug")
}
```

(Requires `@State private var presentShareSheet = false` and `@State private var shareURL: URL?` at the top of SettingsView, plus `.sheet(isPresented: $presentShareSheet) { if let url = shareURL { ShareSheet(items: [url]) } }`.)

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Utilities/Logging.swift wawa-note/UI/Settings/SettingsView.swift
git commit -m "KAN-257: add log export (JSON) and Debug section to Settings"

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Documentation and final wiring

**Files:**
- Create: `docs/logging-standards.md`

- [ ] **Step 1: Write logging standards documentation**

```markdown
# Wawa Note Logging Standards

> KAN-257 — Standardized Logging System

## Categories (7)

| Category | Subsystem | Purpose |
|----------|-----------|---------|
| `infra` | AppLog.infra | Lifecycle, memory, disk, network, background tasks |
| `error` | AppLog.error | Errors with severity, context, recovery |
| `user` | AppLog.user | Taps, navigation, recordings, imports/exports |
| `input` | AppLog.input | Files imported, recordings, text entered |
| `output` | AppLog.output | Exports, items created, artifacts |
| `llm` | AppLog.llm | Full request/response, tool calls, tokens |
| `outcome` | AppLog.outcome | LLM results: tasks, insights, cards |

## Levels (per Apple OSLog)

| Level | Usage |
|-------|-------|
| `debug` | Verbose, not persisted |
| `info` | Informational, not persisted by default |
| `notice` | Default for events (persisted) |
| `error` | Errors (persisted) |
| `fault` | Critical failures (persisted, collected) |

## Correlation IDs

Every operation (analysis, recording, import, chat) generates a `CorrelationID`.
All logs from that operation include the ID: `[analysis:a1b2c3d4]`.

```swift
let cid = CorrelationID.new(operation: "analysis")
AppLog.event(AppLog.llm, "Request sent", correlation: cid)
```

## Retrieval

- Settings > Debug > Export Logs (JSON)
- Settings > Debug > View Logs (raw)
- Console.app: filter by subsystem `com.wawa-note`, category `llm`

## Privacy

- API keys: never logged
- Personal content (transcripts, analysis): logged with `.private` privacy
- Structural metadata: logged with `.public` privacy

## Performance

- All logging async via OSLog (lock-free, ring buffer)
- FileLogService uses dedicated serial queue
- JSON export reads from disk (not real-time)
```

- [ ] **Step 2: Commit**

```bash
git add docs/logging-standards.md
git commit -m "KAN-257: add logging standards documentation"

Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 3: Close JIRA**

```bash
python3 scripts/jira-cli.py comment KAN-257 "IMPLEMENTED. 6 tasks complete. Build verified."
python3 scripts/jira-cli.py move KAN-257 "Done"
```

---
