import Foundation
import OSLog

// MARK: - OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.wawa-note"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let provider = Logger(subsystem: subsystem, category: "provider")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let general = Logger(subsystem: subsystem, category: "general")
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
}

// MARK: - File-logging convenience

extension AppLog {
    /// Logs a critical lifecycle event to both OSLog and the persistent file log.
    /// Usage: AppLog.event("audio", "Recording started with AirPods")
    static func event(_ category: String, _ message: String) {
        FileLogService.shared.log(category: category, level: "EVENT", message: message)
        switch category {
        case "audio": audio.info("\(message)")
        case "transcription": transcription.info("\(message)")
        case "provider": provider.info("\(message)")
        case "storage": storage.info("\(message)")
        case "general": general.info("\(message)")
        default: general.info("[\(category)] \(message)")
        }
    }

    /// Logs a detailed trace with file+line to the persistent log.
    static func debug(_ category: String, _ message: String, file: String = #file, line: Int = #line) {
        let src = "\(file.split(separator: "/").last ?? ""):\(line)"
        FileLogService.shared.log(category: category, level: "DEBUG", message: "\(src) — \(message)")
    }
}
