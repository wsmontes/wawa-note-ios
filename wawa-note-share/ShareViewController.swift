import UIKit
import UniformTypeIdentifiers

private let appGroupIdentifier = "group.com.wawa-note"
private let sharedDirectoryName = "shared"
private let pendingImportFilesKey = "pendingImportFiles"

final class ShareViewController: UIViewController {

    private var savedFiles: [String] = []
    private var processingDone = false
    private var hasErrors = false

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
            NSLog("[WawaShare] App Group container not available — cannot import")
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
                NSLog("[WawaShare] No supported type for: \(provider.registeredTypeIdentifiers)")
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.savedFiles = saved
            if saved.isEmpty {
                NSLog("[WawaShare] No files saved (errors: \(errorCount))")
                self?.hasErrors = true
            } else {
                let shared = UserDefaults(suiteName: appGroupIdentifier)
                shared?.set(saved, forKey: pendingImportFilesKey)
                NSLog("[WawaShare] Saved \(saved.count) files (errors: \(errorCount)): \(saved)")
            }
            self?.processingDone = true
            if self?.isViewLoaded == true, self?.view.window != nil {
                self?.complete()
            }
        }

        // Safety timeout: complete anyway after deadline
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, !self.processingDone else { return }
            NSLog("[WawaShare] Timed out waiting for attachments — completing with \(saved.count) files saved")
            self.savedFiles = saved
            if !saved.isEmpty {
                let shared = UserDefaults(suiteName: appGroupIdentifier)
                shared?.set(saved, forKey: pendingImportFilesKey)
            }
            self.processingDone = true
            if self.isViewLoaded, self.view.window != nil {
                self.complete()
            }
        }
    }

    // MARK: - File copy

    private func loadFile(from provider: NSItemProvider, typeIdentifier: String, containerURL: URL, completion: @escaping (String?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
            if let error {
                NSLog("[WawaShare] loadFileRepresentation error: \(error.localizedDescription)")
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
            NSLog("[WawaShare] Received: \(originalName) -> \(safeName)")

            let sharedDir = containerURL.appendingPathComponent(sharedDirectoryName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
                let destURL = sharedDir.appendingPathComponent(safeName)
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: url, to: destURL)
                NSLog("[WawaShare] Copied to: \(destURL.path)")
                completion(safeName)
            } catch {
                NSLog("[WawaShare] Copy error: \(error.localizedDescription)")
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
