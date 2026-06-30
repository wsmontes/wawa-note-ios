import Foundation

// Related JIRA: KAN-57

/// Safely backs up SwiftData store files before destructive operations.
/// Copies .store, .store-shm, .store-wal to a timestamped recovery directory.
struct StoreBackup {

    /// Root directory for all backups: Documents/Recovery/
    static var recoveryDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Recovery", isDirectory: true)
    }

    /// Creates a timestamped backup of all store files found in the given directories.
    /// Returns the backup folder URL on success, nil if no files were found to back up.
    @discardableResult
    static func backup() -> URL? {
        let fm = FileManager.default
        let storeURLs = locateStoreFiles()
        guard !storeURLs.isEmpty else { return nil }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDir = recoveryDirectory.appendingPathComponent(timestamp, isDirectory: true)

        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            AppLog.warn("general", "StoreBackup: failed to create backup dir: \(error.localizedDescription)")
            return nil
        }

        var copiedCount = 0
        for url in storeURLs {
            let dest = backupDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.copyItem(at: url, to: dest)
                copiedCount += 1
            } catch {
                AppLog.warn("general", "StoreBackup: failed to copy \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if copiedCount > 0 {
            AppLog.general.info("StoreBackup: backed up \(copiedCount) file(s) to \(backupDir.lastPathComponent)")
            pruneOldBackups()
            return backupDir
        } else {
            try? fm.removeItem(at: backupDir)
            return nil
        }
    }

    /// Lists available backup folders sorted by date (newest first).
    static func availableBackups() -> [BackupEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: recoveryDirectory.path) else { return [] }
        let contents = (try? fm.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return
            contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { url -> BackupEntry? in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
                return BackupEntry(url: url, date: date, files: files)
            }
            .sorted { $0.date > $1.date }
    }

    /// Deletes a specific backup.
    static func deleteBackup(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    /// Finds all existing store files (main + app group containers).
    private static func locateStoreFiles() -> [URL] {
        let fm = FileManager.default
        var searchDirs: [URL] = []

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            searchDirs.append(appSupport)
        }
        if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") {
            searchDirs.append(groupURL.appendingPathComponent("Library/Application Support"))
        }

        var found: [URL] = []
        for dir in searchDirs {
            let storeBase = dir.appendingPathComponent("default.store")
            let companions = [storeBase.path, storeBase.path + "-shm", storeBase.path + "-wal"]
            for path in companions {
                if fm.fileExists(atPath: path) {
                    found.append(URL(fileURLWithPath: path))
                }
            }
        }
        return found
    }

    /// Keeps only the 5 most recent backups. Deletes older ones.
    private static func pruneOldBackups(maxKeep: Int = 5) {
        let backups = availableBackups()
        guard backups.count > maxKeep else { return }
        for entry in backups.dropFirst(maxKeep) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}

// MARK: - BackupEntry

struct BackupEntry: Identifiable {
    let url: URL
    let date: Date
    let files: [String]

    var id: URL { url }

    var label: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    var sizeDescription: String {
        let total = files.reduce(0) { sum, name in
            let fileURL = url.appendingPathComponent(name)
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + size
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
