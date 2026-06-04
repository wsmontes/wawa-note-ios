import Foundation
import UIKit
import OSLog

/// Persistent file-based logger that survives crashes.
/// Writes timestamped, categorized entries to a rotating log file in the app's
/// Caches directory. Each write flushes immediately so logs are preserved even
/// if the app terminates abnormally.
final class FileLogService {
    static let shared = FileLogService()

    private let fileManager = FileManager.default
    private let logQueue = DispatchQueue(label: "com.wawa-note.filelog", qos: .utility)
    private let dateFormatter: ISO8601DateFormatter
    private let simpleFormatter: DateFormatter

    private var currentLogURL: URL {
        cachesDir.appendingPathComponent("wawa-debug.log")
    }
    private var previousLogURL: URL {
        cachesDir.appendingPathComponent("wawa-debug.prev.log")
    }
    private var crashSentinelURL: URL {
        cachesDir.appendingPathComponent("wawa-crash-sentinel.txt")
    }

    /// Maximum log file size in bytes (1 MB)
    private let maxLogSize: Int64 = 1_048_576

    /// Number of old rotated logs to keep
    private let maxRotatedLogs = 3

    private var cachesDir: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    /// Whether the previous app session ended with a crash.
    private(set) var previousSessionCrashed = false

    private init() {
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        simpleFormatter = DateFormatter()
        simpleFormatter.dateFormat = "HH:mm:ss.SSS"

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
        // Create/recreate the sentinel — it will be deleted on clean exit
        try? "running".write(to: crashSentinelURL, atomically: true, encoding: .utf8)
    }

    /// Call this when the app is about to terminate cleanly (UIApplication.willTerminate).
    func markCleanExit() {
        try? fileManager.removeItem(at: crashSentinelURL)
    }

    /// Call this periodically during normal operation to confirm the app is healthy.
    func heartbeat() {
        try? "running".write(to: crashSentinelURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Session

    private func logSessionStart() {
        let device = UIDevice.current
        let info = [
            "session_start",
            "device=\(device.model) (\(device.systemName) \(device.systemVersion))",
            "app_version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
            "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")",
            previousSessionCrashed ? "⚠️ PREVIOUS_SESSION_CRASHED" : "clean_launch"
        ].joined(separator: " ")
        writeRaw(info)
    }

    // MARK: - Writing

    func log(category: String, level: String, message: String) {
        let timestamp = simpleFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
        logQueue.async { [weak self] in
            self?.writeRaw(line)
        }
    }

    private func writeRaw(_ text: String) {
        rotateIfNeeded()

        guard let data = text.data(using: .utf8) else { return }

        if fileManager.fileExists(atPath: currentLogURL.path) {
            guard let handle = try? FileHandle(forWritingTo: currentLogURL) else {
                try? data.write(to: currentLogURL, options: .atomic)
                return
            }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            // Immediate fsync so logs survive a crash
            try? handle.synchronize()
        } else {
            try? data.write(to: currentLogURL, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? fileManager.attributesOfItem(atPath: currentLogURL.path),
              let size = attrs[.size] as? Int64,
              size >= maxLogSize else { return }

        // Rotate: current → .0, .0 → .1, .1 → .2, drop .3+

        // Remove oldest rotation
        let oldestURL = cachesDir.appendingPathComponent("wawa-debug.\(maxRotatedLogs).log")
        try? fileManager.removeItem(at: oldestURL)

        // Shift rotations
        for i in stride(from: maxRotatedLogs - 1, through: 0, by: -1) {
            let src = i == 0 ? currentLogURL : cachesDir.appendingPathComponent("wawa-debug.\(i).log")
            let dst = cachesDir.appendingPathComponent("wawa-debug.\(i + 1).log")
            try? fileManager.moveItem(at: src, to: dst)
        }

        // Create fresh log file
        try? "".write(to: currentLogURL, atomically: true, encoding: .utf8)
    }

    private func createLogFileIfNeeded() {
        if !fileManager.fileExists(atPath: currentLogURL.path) {
            try? "".write(to: currentLogURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Retrieval

    /// Returns the contents of all available log files, newest first.
    func retrieveLogs() -> String {
        var result = ""

        // Collect all log files sorted by modification date (newest first)
        var allFiles: [(URL, Date)] = []
        let enumerator = fileManager.enumerator(at: cachesDir, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasPrefix("wawa-debug") && name.hasSuffix(".log") {
                if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    allFiles.append((url, date))
                }
            }
        }
        allFiles.sort { $0.1 > $1.1 }

        for (url, _) in allFiles {
            if let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
                if !result.isEmpty { result += "\n--- \(url.lastPathComponent) ---\n\n" }
                result += content
            }
        }

        return result
    }

    /// Creates a temporary file with all logs for sharing via UIActivityViewController.
    func exportLogs() -> URL? {
        let logs = retrieveLogs()
        guard !logs.isEmpty else { return nil }

        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("wawa-note-debug-\(ISO8601DateFormatter().string(from: Date())).log")
        try? logs.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    /// Clears all log files.
    func clearLogs() {
        logQueue.async { [weak self] in
            guard let self else { return }
            let enumerator = self.fileManager.enumerator(at: self.cachesDir, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let name = url.lastPathComponent
                if name.hasPrefix("wawa-debug") && name.hasSuffix(".log") {
                    try? self.fileManager.removeItem(at: url)
                }
            }
            self.createLogFileIfNeeded()
        }
    }
}
