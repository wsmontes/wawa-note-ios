import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            complete()
            return
        }

        var handled = false
        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                // Try audio first, then movie, then generic file
                let types: [String] = [
                    UTType.audio.identifier,
                    UTType.movie.identifier,
                    UTType.fileURL.identifier,
                    UTType.data.identifier
                ]
                for typeID in types {
                    if provider.hasItemConformingToTypeIdentifier(typeID) {
                        loadFile(from: provider, typeIdentifier: typeID)
                        handled = true
                        break
                    }
                }
                if handled { break }
            }
            if handled { break }
        }

        if !handled { complete() }
    }

    private func loadFile(from provider: NSItemProvider, typeIdentifier: String) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            guard let self else { return }

            if let error {
                NSLog("[WawaShare] loadFileRepresentation error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.complete() }
                return
            }

            guard let url = url else {
                DispatchQueue.main.async { self.complete() }
                return
            }

            let originalName = provider.suggestedName ?? url.lastPathComponent
            let safeName = safeImportFilename(original: originalName)
            NSLog("[WawaShare] Received file: \(originalName), saving as \(safeName)")

            guard let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.wawa-note") else {
                NSLog("[WawaShare] No App Group container")
                DispatchQueue.main.async { self.complete() }
                return
            }

            let sharedDir = containerURL.appendingPathComponent("shared", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
                let destURL = sharedDir.appendingPathComponent(safeName)
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: url, to: destURL)
                NSLog("[WawaShare] File copied to: \(destURL.path)")

                let shared = UserDefaults(suiteName: "group.com.wawa-note")
                shared?.set(safeName, forKey: "pendingImportFile")
                shared?.synchronize()
            } catch {
                NSLog("[WawaShare] File copy error: \(error.localizedDescription)")
            }

            DispatchQueue.main.async { self.complete() }
        }
    }

    private func safeImportFilename(original: String) -> String {
        let sanitized = original
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        return "\(UUID().uuidString)-\(sanitized)"
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)

        // Open main app
        guard let url = URL(string: "wawanote://import") else { return }
        var responder: UIResponder? = self
        while responder != nil {
            if let app = responder as? UIApplication {
                app.open(url, options: [:]) { success in
                    NSLog("[WawaShare] openURL result: \(success)")
                }
                break
            }
            responder = responder?.next
        }
    }
}
