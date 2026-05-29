import Foundation
import OSLog

@MainActor
final class ModelDownloadService: ObservableObject {
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadStatus: [String: DownloadStatus] = [:]

    enum DownloadStatus: Equatable {
        case idle
        case downloading
        case verifying
        case installed
        case failed(String)
    }

    private let registry: ModelRegistry
    private var tasks: [String: Task<Void, Never>] = [:]

    init(registry: ModelRegistry = ModelRegistry()) {
        self.registry = registry
    }

    // MARK: - Model catalog

    static let availableModels: [ModelDescriptor] = [
        ModelDescriptor(
            modelId: "qwen-2.5-1.5b",
            displayName: "Qwen 2.5 1.5B",
            description: "Summarization, task extraction, structured output. Multilingual.",
            fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            downloadURL: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            sizeBytes: 1_100_000_000,
            sha256: nil
        ),
        ModelDescriptor(
            modelId: "embeddinggemma-300m",
            displayName: "EmbeddingGemma 300M",
            description: "Semantic search embeddings. 100+ languages.",
            fileName: "embeddinggemma-300m-Q4_K_M.gguf",
            downloadURL: "https://huggingface.co/second-state/embeddinggemma-300m-GGUF/resolve/main/embeddinggemma-300m-Q4_K_M.gguf",
            sizeBytes: 247_463_936,
            sha256: nil
        )
    ]

    // MARK: - Download

    func download(_ descriptor: ModelDescriptor) {
        guard downloadStatus[descriptor.modelId] != .installed else { return }
        guard downloadStatus[descriptor.modelId] != .downloading else { return }

        tasks[descriptor.modelId]?.cancel()
        downloadProgress[descriptor.modelId] = 0
        downloadStatus[descriptor.modelId] = .downloading

        let destDir = registry.modelDirectory()
        let destURL = destDir.appendingPathComponent(descriptor.fileName)

        tasks[descriptor.modelId] = Task {
            do {
                guard let url = URL(string: descriptor.downloadURL) else {
                    throw DownloadError.invalidURL
                }

                // Download to temp file
                let (tempURL, response) = try await URLSession.shared.download(from: url)

                let httpResponse = response as? HTTPURLResponse
                guard httpResponse?.statusCode == 200 else {
                    throw DownloadError.verificationFailed
                }

                // Verify size
                let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                let downloadedSize = attrs[.size] as? Int64 ?? 0
                let expectedMin = descriptor.sizeBytes / 2
                guard downloadedSize > expectedMin else {
                    AppLog.general.error("Download too small: \(downloadedSize) bytes (expected ~\(descriptor.sizeBytes))")
                    throw DownloadError.verificationFailed
                }

                AppLog.general.info("Downloaded \(descriptor.modelId): \(downloadedSize) bytes")

                // Move to models directory
                downloadStatus[descriptor.modelId] = .verifying
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.moveItem(at: tempURL, to: destURL)

                let entry = ModelEntry(
                    modelId: descriptor.modelId,
                    fileName: descriptor.fileName,
                    displayName: descriptor.displayName,
                    version: "1.0",
                    sizeBytes: downloadedSize,
                    sha256: descriptor.sha256,
                    downloadedAt: Date(),
                    isActive: true
                )
                try registry.markInstalled(modelId: descriptor.modelId, entry: entry)

                downloadProgress[descriptor.modelId] = 1.0
                downloadStatus[descriptor.modelId] = .installed
                AppLog.general.info("Model installed: \(descriptor.modelId)")
            } catch {
                if error is CancellationError { return }
                downloadStatus[descriptor.modelId] = .failed(error.localizedDescription)
                AppLog.general.error("Download failed: \(descriptor.modelId) — \(error)")
                try? FileManager.default.removeItem(at: destURL)
            }
        }
    }

    func cancel(_ modelId: String) {
        tasks[modelId]?.cancel()
        tasks[modelId] = nil
    }

    func deleteModel(_ modelId: String) throws {
        cancel(modelId)
        try registry.markUninstalled(modelId)
        downloadProgress[modelId] = nil
        downloadStatus[modelId] = .idle
    }
}

struct ModelDescriptor: Identifiable {
    let modelId: String
    let displayName: String
    let description: String
    let fileName: String
    let downloadURL: String
    let sizeBytes: Int64
    let sha256: String?

    var id: String { modelId }

    var sizeFormatted: String {
        let mb = Double(sizeBytes) / 1_048_576
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.0f MB", mb)
    }
}

enum DownloadError: Error {
    case invalidURL
    case verificationFailed
}
