import Foundation
import OSLog
// Related JIRA: KAN-11, KAN-257


// MARK: - OSLog (KAN-257: Standardized 7-category logging)

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.wawa-note"

    // INFRA: app lifecycle, memory, disk, network, background tasks, crash recovery
    static let infra = Logger(subsystem: subsystem, category: "infra")
    // ERRORS: all errors with severity, context, stack trace, recovery action
    static let error = Logger(subsystem: subsystem, category: "error")
    // USER_INTERACTION: taps, navigation, recordings, imports/exports, project ops
    static let user = Logger(subsystem: subsystem, category: "user")
    // DATA_INPUT: files imported, recordings captured, text entered, URLs bookmarked
    static let input = Logger(subsystem: subsystem, category: "input")
    // DATA_OUTPUT: exports, items created, analysis artifacts, cards rendered
    static let output = Logger(subsystem: subsystem, category: "output")
    // LLM_COMMUNICATION: full request/response, tool calls, tokens, latency
    static let llm = Logger(subsystem: subsystem, category: "llm")
    // OUTCOMES: tasks created, insights generated, cards rendered from LLM calls
    static let outcome = Logger(subsystem: subsystem, category: "outcome")

    // Legacy aliases — migrate callers gradually
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
    @available(*, deprecated, message: "Use AppLog.llm")
    static let agent = Logger(subsystem: subsystem, category: "llm")
    @available(*, deprecated, message: "Use AppLog.infra")
    static let config = Logger(subsystem: subsystem, category: "infra")
}

// MARK: - Correlation ID (KAN-257)

/// Links all logs from a single operation (analysis run, recording, import).
struct CorrelationID: Sendable, CustomStringConvertible {
    let value: String
    let operation: String

    var description: String { "\(operation):\(value.prefix(8))" }

    static func new(operation: String) -> CorrelationID {
        CorrelationID(value: UUID().uuidString, operation: operation)
    }

    static let app = CorrelationID(value: "app", operation: "system")
}

// MARK: - Structured Log Entry (KAN-257)

struct LogEntry: Codable, Sendable {
    let timestamp: String
    let level: String
    let category: String
    let correlation: String?
    let message: String
    let metadata: [String: String]?
}

// MARK: - AppLog Convenience Methods (KAN-257)

extension AppLog {
    /// Log a user event with optional correlation ID.
    static func event(_ category: Logger, _ message: String, cat: String = "general", correlation: CorrelationID? = nil) {
        var msg = message
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        category.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: cat, level: "event", message: msg)
    }

    /// Log a warning with optional correlation ID.
    static func warn(_ category: Logger, _ message: String, cat: String = "general", correlation: CorrelationID? = nil) {
        var msg = message
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        category.warning("\(msg, privacy: .public)")
        FileLogService.shared.log(category: cat, level: "warn", message: msg)
    }

    /// Log an error with optional correlation ID.
    static func logError(_ category: Logger, _ message: String, cat: String = "general", correlation: CorrelationID? = nil) {
        var msg = message
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        category.error("\(msg, privacy: .public)")
        FileLogService.shared.log(category: cat, level: "error", message: msg)
    }
}

// MARK: - LLM Communication Logging (KAN-257)

extension AppLog {
    /// Log an LLM request with privacy-annotated metadata.
    static func llmRequest(
        model: String, provider: String,
        messageCount: Int, toolCount: Int,
        maxTokens: Int?, temperature: Double?,
        correlation: CorrelationID? = nil
    ) {
        var msg = "LLM_REQ model=\(model) provider=\(provider) messages=\(messageCount) tools=\(toolCount)"
        if let mt = maxTokens { msg += " maxTokens=\(mt)" }
        if let t = temperature { msg += " temp=\(t)" }
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        AppLog.llm.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: "llm", level: "request", message: msg)
    }

    /// Log an LLM response with token usage and latency.
    static func llmResponse(
        model: String, contentLength: Int, toolCalls: Int,
        inputTokens: Int, outputTokens: Int, latencyMs: Int64,
        correlation: CorrelationID? = nil
    ) {
        var msg = "LLM_RES model=\(model) contentLen=\(contentLength) toolCalls=\(toolCalls) tokensIn=\(inputTokens) tokensOut=\(outputTokens) latencyMs=\(latencyMs)"
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        AppLog.llm.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: "llm", level: "response", message: msg)
    }

    /// Log a tool call execution.
    static func llmToolCall(
        tool: String, argsLength: Int, resultLength: Int,
        isError: Bool, correlation: CorrelationID? = nil
    ) {
        var msg = "LLM_TOOL tool=\(tool) argsLen=\(argsLength) resultLen=\(resultLength) error=\(isError)"
        if let cid = correlation { msg = "[\(cid)] \(msg)" }
        AppLog.llm.notice("\(msg, privacy: .public)")
        FileLogService.shared.log(category: "llm", level: "tool", message: msg)
    }
}

// MARK: - FileLogService (persistent, crash-safe)

/// Persistent file-based logger that survives crashes.
/// Writes timestamped, categorized entries to a rotating log file in Caches.
/// Each write flushes immediately so logs are preserved even on abnormal exit.
final class FileLogService: @unchecked Sendable {
    static let shared = FileLogService()

    private let fileManager = FileManager.default
    private let logQueue = DispatchQueue(label: "com.wawa-note.filelog", qos: .utility)
    private let dateFormatter: DateFormatter

    private var currentLogURL: URL {
        cachesDir.appendingPathComponent("wawa-debug.log")
    }
    private var crashSentinelURL: URL {
        cachesDir.appendingPathComponent(".wawa-crash-sentinel")
    }

    /// Maximum log file size in bytes (~1 MB)
    private let maxLogSize: Int64 = 1_048_576
    private let maxRotatedLogs = 3

    private var cachesDir: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    /// Whether the previous app session ended with a crash.
    private(set) var previousSessionCrashed = false

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        createLogFileIfNeeded()
        detectPreviousCrash()
        logSessionStart()
    }

    // MARK: - Crash detection

    /// Creates a sentinel file when the app starts. If the sentinel already
    /// exists from a previous session, the app was terminated abnormally.
    private func detectPreviousCrash() {
        if fileManager.fileExists(atPath: crashSentinelURL.path) {
            previousSessionCrashed = true
        }
        try? "1".write(to: crashSentinelURL, atomically: true, encoding: .utf8)
    }

    func markCleanExit() {
        try? fileManager.removeItem(at: crashSentinelURL)
    }

    func heartbeat() {
        try? "1".write(to: crashSentinelURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Session

    private func logSessionStart() {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iPhone"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let info = "SESSION_START device=\(model) os=\(osStr) app=\(version)(\(build)) \(previousSessionCrashed ? "⚠️ PREVIOUS_CRASH" : "clean")\n"
        logQueue.async { [weak self] in self?.writeRaw(info) }
    }

    // MARK: - Public API

    func log(category: String, level: String, message: String) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"
        logQueue.async { [weak self] in self?.writeRaw(line) }
    }

    func retrieveLogs() -> String {
        var result = ""
        var allFiles: [(URL, Date)] = []
        if let e = fileManager.enumerator(at: cachesDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in e {
                let name = url.lastPathComponent
                if name.hasPrefix("wawa-debug") && name.hasSuffix(".log") {
                    if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        allFiles.append((url, d))
                    }
                }
            }
        }
        allFiles.sort { $0.1 > $1.1 }
        for (url, _) in allFiles {
            if let c = try? String(contentsOf: url, encoding: .utf8), !c.isEmpty {
                if !result.isEmpty { result += "\n--- \(url.lastPathComponent) ---\n\n" }
                result += c
            }
        }
        return result
    }

    func exportLogs() -> URL? {
        let logs = retrieveLogs()
        guard !logs.isEmpty else { return nil }
        let name = "wawa-debug-\(ISO8601DateFormatter().string(from: Date())).log"
        let tmp = fileManager.temporaryDirectory.appendingPathComponent(name)
        try? logs.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    func clearLogs() {
        logQueue.async { [weak self] in
            guard let self else { return }
            if let e = self.fileManager.enumerator(at: self.cachesDir, includingPropertiesForKeys: nil) {
                for case let url as URL in e {
                    let n = url.lastPathComponent
                    if n.hasPrefix("wawa-debug") && n.hasSuffix(".log") {
                        try? self.fileManager.removeItem(at: url)
                    }
                }
            }
            self.createLogFileIfNeeded()
        }
    }

    // MARK: - Private

    private func writeRaw(_ text: String) {
        rotateIfNeeded()
        guard let data = text.data(using: .utf8) else { return }
        if fileManager.fileExists(atPath: currentLogURL.path) {
            guard let fh = try? FileHandle(forWritingTo: currentLogURL) else {
                try? data.write(to: currentLogURL, options: .atomic)
                return
            }
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
            try? fh.synchronize()
        } else {
            try? data.write(to: currentLogURL, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? fileManager.attributesOfItem(atPath: currentLogURL.path),
              let size = attrs[.size] as? Int64, size >= maxLogSize else { return }
        let oldest = cachesDir.appendingPathComponent("wawa-debug.\(maxRotatedLogs).log")
        try? fileManager.removeItem(at: oldest)
        for i in stride(from: maxRotatedLogs - 1, through: 0, by: -1) {
            let src = i == 0 ? currentLogURL : cachesDir.appendingPathComponent("wawa-debug.\(i).log")
            let dst = cachesDir.appendingPathComponent("wawa-debug.\(i + 1).log")
            try? fileManager.moveItem(at: src, to: dst)
        }
        try? "".write(to: currentLogURL, atomically: true, encoding: .utf8)
    }

    private func createLogFileIfNeeded() {
        if !fileManager.fileExists(atPath: currentLogURL.path) {
            try? "".write(to: currentLogURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - JSON Export (KAN-257)

    /// Export logs as structured JSON array for sharing or external analysis.
    func exportLogsJSON() -> Data {
        let text = retrieveLogs()
        let lines = text.split(separator: "\n")
        let jsonLines: [[String: String]] = lines.compactMap { line in
            let raw = String(line)
            let parts = raw.split(separator: "]", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            let ts = String(parts[0].dropFirst())
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
}

// MARK: - File-logging convenience

extension AppLog {
    /// Logs a critical lifecycle event to both OSLog and the persistent file log.
    /// Usage: AppLog.event("audio", "Recording started with AirPods")
    /// API keys are automatically redacted via sanitizedForLog.
    static func event(_ category: String, _ message: String) {
        let safe = message.sanitizedForLog
        FileLogService.shared.log(category: category, level: "EVENT", message: safe)
        switch category {
        case "audio": audio.info("\(safe)")
        case "transcription": transcription.info("\(safe)")
        case "provider": provider.info("\(safe)")
        case "storage": storage.info("\(safe)")
        case "agent": agent.info("\(safe)")
        case "config": config.info("\(safe)")
        case "general": general.info("\(safe)")
        default: general.info("[\(category)] \(safe)")
        }
    }

    /// Logs a warning to both OSLog and the persistent file log.
    /// Use for recoverable error states that may precede a crash.
    /// API keys are automatically redacted via sanitizedForLog.
    static func warn(_ category: String, _ message: String) {
        let safe = message.sanitizedForLog
        FileLogService.shared.log(category: category, level: "WARN", message: safe)
        switch category {
        case "audio": audio.warning("\(safe)")
        case "transcription": transcription.warning("\(safe)")
        case "provider": provider.warning("\(safe)")
        case "storage": storage.warning("\(safe)")
        case "agent": agent.warning("\(safe)")
        case "config": config.warning("\(safe)")
        case "general": general.warning("\(safe)")
        default: general.warning("[\(category)] \(safe)")
        }
    }

    /// Logs an error to both OSLog and the persistent file log.
    /// Use for every error that could be crash-adjacent.
    /// API keys are automatically redacted via sanitizedForLog.
    static func error(_ category: String, _ message: String) {
        let safe = message.sanitizedForLog
        FileLogService.shared.log(category: category, level: "ERROR", message: safe)
        switch category {
        case "audio": audio.error("\(safe)")
        case "transcription": transcription.error("\(safe)")
        case "provider": provider.error("\(safe)")
        case "storage": storage.error("\(safe)")
        case "agent": agent.error("\(safe)")
        case "config": config.error("\(safe)")
        case "general": general.error("\(safe)")
        default: general.error("[\(category)] \(safe)")
        }
    }

    /// Logs a detailed trace with file+line to the persistent log.
    /// API keys are automatically redacted via sanitizedForLog.
    static func debug(_ category: String, _ message: String, file: String = #file, line: Int = #line) {
        let src = "\(file.split(separator: "/").last ?? ""):\(line)"
        let safe = message.sanitizedForLog
        FileLogService.shared.log(category: category, level: "DEBUG", message: "\(src) — \(safe)")
    }
}

// MARK: - API Key Sanitization

extension String {
    /// Replaces API key patterns with [REDACTED] for safe logging.
    /// Detects: sk-... (OpenAI), sk-ant-... (Anthropic), org-... (OpenAI org),
    /// AIza... (Google), hf_... (HuggingFace), and generic Bearer tokens.
    var sanitizedForLog: String {
        let patterns: [(String, String)] = [
            ("sk-[a-zA-Z0-9_-]{20,}", "sk-[REDACTED]"),
            ("sk-ant-[a-zA-Z0-9_-]{20,}", "sk-ant-[REDACTED]"),
            ("org-[a-zA-Z0-9_-]{20,}", "org-[REDACTED]"),
            ("AIza[0-9A-Za-z_-]{30,}", "AIza[REDACTED]"),
            ("hf_[a-zA-Z0-9]{20,}", "hf_[REDACTED]"),
            ("Bearer [a-zA-Z0-9_\\-\\.]{20,}", "Bearer [REDACTED]"),
            ("x-api-key: [a-zA-Z0-9_\\-\\.]{10,}", "x-api-key: [REDACTED]"),
        ]
        var result = self
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: replacement)
            }
        }
        return result
    }
}
