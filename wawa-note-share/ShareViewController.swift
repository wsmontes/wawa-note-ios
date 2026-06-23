import UIKit
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "com.wawa-note.share", category: "share-extension")
private let appGroupIdentifier = "group.com.wawa-note"
private let sharedDirectoryName = "shared"
private let pendingImportFilesKey = "pendingImportFiles"

final class ShareViewController: UIViewController {

    private var savedFiles: [String] = []
    private var processingDone = false
    private var hasErrors = false
    /// Serializes access to the completion path so that the group.notify and
    /// safety timeout handlers don't race on UserDefaults writes + complete().
    private let completionLock = OSAllocatedUnfairLock()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        processAttachments()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if processingDone {
            complete()
        }
    }

    // MARK: - Attachment processing

    private func processAttachments() {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            logger.info(" App Group container not available — cannot import")
            processingDone = true
            hasErrors = true
            return
        }

        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            processingDone = true
            return
        }

        let allProviders: [NSItemProvider] = extensionItems.compactMap { $0.attachments }.flatMap { $0 }

        guard !allProviders.isEmpty else {
            processingDone = true
            return
        }

        let group = DispatchGroup()
        var saved: [String] = []
        var errorCount = 0
        let lock = NSLock()

        // Timeout after 25 seconds to stay within system's ~30s limit
        let deadline = DispatchTime.now() + .seconds(25)

        for provider in allProviders {
            let types: [String] = [
                UTType.audio.identifier,
                UTType.movie.identifier,
                UTType.fileURL.identifier,
                UTType.data.identifier
            ]

            var matched = false
            for typeID in types {
                if provider.hasItemConformingToTypeIdentifier(typeID) {
                    group.enter()
                    loadFile(from: provider, typeIdentifier: typeID, containerURL: containerURL) { filename in
                        lock.lock()
                        if let name = filename {
                            saved.append(name)
                        } else {
                            errorCount += 1
                        }
                        lock.unlock()
                        group.leave()
                    }
                    matched = true
                    break
                }
            }
            if !matched {
                logger.info(" No supported type for: \(provider.registeredTypeIdentifiers)")
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.completionLock.lock()
            guard !self.processingDone else { self.completionLock.unlock(); return }
            self.savedFiles = saved
            if saved.isEmpty {
                logger.info(" No files saved (errors: \(errorCount))")
                self.hasErrors = true
            } else {
                let shared = UserDefaults(suiteName: appGroupIdentifier)
                shared?.set(saved, forKey: pendingImportFilesKey)
                logger.info(" Saved \(saved.count) files (errors: \(errorCount)): \(saved)")
                // Open the main app to trigger import
                if let url = URL(string: "wawanote://import") {
                    self.extensionContext?.open(url)
                }
            }
            self.processingDone = true
            self.completionLock.unlock()
            if self.isViewLoaded, self.view.window != nil {
                self.complete()
            }
        }

        // Safety timeout: complete anyway after deadline
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.completionLock.lock()
            guard !self.processingDone else { self.completionLock.unlock(); return }
            logger.info(" Timed out waiting for attachments — completing with \(saved.count) files saved")
            self.savedFiles = saved
            if !saved.isEmpty {
                let shared = UserDefaults(suiteName: appGroupIdentifier)
                shared?.set(saved, forKey: pendingImportFilesKey)
                // Open the main app to trigger import
                if let url = URL(string: "wawanote://import") {
                    self.extensionContext?.open(url)
                }
            }
            self.processingDone = true
            self.completionLock.unlock()
            if self.isViewLoaded, self.view.window != nil {
                self.complete()
            }
        }
    }

    // MARK: - File copy

    private func loadFile(from provider: NSItemProvider, typeIdentifier: String, containerURL: URL, completion: @escaping (String?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
            if let error {
                logger.info(" loadFileRepresentation error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let url = url else {
                completion(nil)
                return
            }

            defer {
                // Clean up system-provided temp file
                try? FileManager.default.removeItem(at: url)
            }

            let originalName = provider.suggestedName ?? url.lastPathComponent
            let safeName = Self.safeImportFilename(original: originalName)
            logger.info(" Received: \(originalName) -> \(safeName)")

            let sharedDir = containerURL.appendingPathComponent(sharedDirectoryName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
                let destURL = sharedDir.appendingPathComponent(safeName)
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: url, to: destURL)
                logger.info(" Copied to: \(destURL.path)")
                completion(safeName)
            } catch {
                logger.info(" Copy error: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    private static func safeImportFilename(original: String) -> String {
        let sanitized = original
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        return "\(UUID().uuidString)-\(sanitized)"
    }

    // MARK: - Complete

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
