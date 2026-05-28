import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private var savedFiles: [String] = []
    private var processingDone = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Transparent background so the share sheet UI is less jarring
        view.backgroundColor = .clear
        processAttachments()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // If processing already finished, complete immediately
        if processingDone {
            complete()
        }
    }

    // MARK: - Attachment processing

    private func processAttachments() {
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
        let queue = DispatchQueue(label: "share.import", qos: .userInitiated)
        var saved: [String] = []

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
                    loadFile(from: provider, typeIdentifier: typeID) { filename in
                        if let name = filename {
                            queue.sync { saved.append(name) }
                        }
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
                NSLog("[WawaShare] No files saved")
            } else {
                let shared = UserDefaults(suiteName: "group.com.wawa-note")
                shared?.set(saved, forKey: "pendingImportFiles")
                NSLog("[WawaShare] Saved \(saved.count) files: \(saved)")
            }
            self?.processingDone = true
            if self?.isViewLoaded == true, self?.view.window != nil {
                self?.complete()
            }
        }
    }

    // MARK: - File copy

    private func loadFile(from provider: NSItemProvider, typeIdentifier: String, completion: @escaping (String?) -> Void) {
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

            let originalName = provider.suggestedName ?? url.lastPathComponent
            let safeName = self.safeImportFilename(original: originalName)
            NSLog("[WawaShare] Received: \(originalName) -> \(safeName)")

            guard let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") else {
                NSLog("[WawaShare] No App Group container")
                completion(nil)
                return
            }

            let sharedDir = containerURL.appendingPathComponent("shared", isDirectory: true)
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

    private nonisolated func safeImportFilename(original: String) -> String {
        let sanitized = original
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        return "\(UUID().uuidString)-\(sanitized)"
    }

    // MARK: - Complete

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
