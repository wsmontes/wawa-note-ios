import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.wawa-note"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let provider = Logger(subsystem: subsystem, category: "provider")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let general = Logger(subsystem: subsystem, category: "general")
}
