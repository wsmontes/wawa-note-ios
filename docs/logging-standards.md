# Wawa Note Logging Standards

> KAN-257 — Standardized Logging System

## Categories (7)

| Category | OSLog | Purpose |
|----------|-------|---------|
| `infra` | AppLog.infra | App lifecycle, memory, disk, network, background tasks, crash recovery |
| `error` | AppLog.error | Errors with severity, context, stack trace, recovery action |
| `user` | AppLog.user | Taps, navigation, recordings started/stopped, imports/exports, project ops |
| `input` | AppLog.input | Files imported, recordings captured, text entered, URLs bookmarked |
| `output` | AppLog.output | Exports generated, items created, analysis artifacts produced, cards rendered |
| `llm` | AppLog.llm | Full request (model, messages, tools, params), full response (content, tool_calls, tokens, latency), parse results, retry attempts |
| `outcome` | AppLog.outcome | What was produced from each LLM call (tasks created, insights generated, cards rendered) |

## Log Levels (per Apple OSLog)

| Level | Usage |
|-------|-------|
| `debug` | Verbose diagnostic info, not persisted to disk by default |
| `info` | Informational, not persisted by default |
| `notice` | Default for events — persisted to disk |
| `error` | Errors — persisted, collected by Console.app |
| `fault` | Critical failures — persisted, collected, triggers sysdiagnose |

## Correlation IDs

Every operation (analysis, recording, import, chat) generates a `CorrelationID`. All logs from that operation include the ID prefix `[operation:xxxxxxxx]`.

```swift
let cid = CorrelationID.new(operation: "analysis")
AppLog.event(AppLog.llm, "Request sent", cat: "llm", correlation: cid)
AppLog.llmRequest(model: "gpt-5.5", provider: "openai", messageCount: 3, toolCount: 5, maxTokens: 4096, temperature: nil, correlation: cid)
```

## LLM Communication Logging

```swift
// Before each LLM call:
AppLog.llmRequest(model: model, provider: provider, messageCount: messages.count, toolCount: tools.count, maxTokens: request.maxTokens, temperature: request.temperature, correlation: cid)

// After each LLM call:
AppLog.llmResponse(model: model, contentLength: response.content.count, toolCalls: response.toolCalls?.count ?? 0, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, latencyMs: elapsed, correlation: cid)

// For each tool execution:
AppLog.llmToolCall(tool: name, argsLength: args.count, resultLength: result.count, isError: false, correlation: cid)
```

## User Interaction Logging

```swift
AppLog.event(AppLog.user, "Recording started: title=\(title)", cat: "user")
AppLog.event(AppLog.user, "Import completed: type=\(format) file=\(name)", cat: "user")
AppLog.event(AppLog.user, "Project viewed: \(project.name)", cat: "user")
```

## Retrieval

- **Settings > Debug > Export Logs (JSON):** Tap to export all logs as structured JSON via share sheet
- **Settings > Debug > Log Size:** Shows current log file size
- **Console.app:** Filter by subsystem `com.wawa-note`, category `llm` (or any category)
- **File location:** `~/Library/Caches/wawa-debug.log` (rotating, max 1MB × 3)

## Privacy

- **API keys:** Redacted via `String.sanitizedForLog` — replaces `sk-...`, `sk-ant-...`, `AIza...`, `hf_...`, and Bearer token patterns with `[REDACTED]`
- **Personal content (transcripts, analysis):** Use OSLog `.private` privacy level
- **Structural metadata:** Use `.public` privacy level (model names, counts, latencies)

## Performance

- All OSLog writes are async and lock-free (ring buffer)
- FileLogService uses dedicated serial dispatch queue
- JSON export reads from disk on demand (not real-time)

## Migration from Legacy Categories

| Legacy | New |
|--------|-----|
| `AppLog.audio` | `AppLog.infra` |
| `AppLog.transcription` | `AppLog.infra` |
| `AppLog.provider` | `AppLog.llm` |
| `AppLog.storage` | `AppLog.infra` |
| `AppLog.general` | `AppLog.infra` |
| `AppLog.agent` | `AppLog.llm` |
| `AppLog.config` | `AppLog.infra` |

Legacy aliases are available with `@available(*, deprecated)` — migrate callers gradually.
