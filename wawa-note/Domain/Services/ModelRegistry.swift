import Foundation

struct ModelEntry: Codable, Identifiable {
    let modelId: String
    let fileName: String
    let displayName: String
    let version: String
    let sizeBytes: Int64
    let sha256: String?
    let downloadedAt: Date
    var isActive: Bool

    var id: String { modelId }

    var sizeFormatted: String {
        let mb = Double(sizeBytes) / 1_048_576
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.0f MB", mb)
    }
}

final class ModelRegistry: @unchecked Sendable {
    private let fileManager: FileManager
    private let modelsDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectory = appSupport.appendingPathComponent("models", isDirectory: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Registry file

    private var registryURL: URL {
        modelsDirectory.appendingPathComponent("models.json")
    }

    private func loadRegistry() -> [String: ModelEntry] {
        guard let data = try? Data(contentsOf: registryURL),
              let dict = try? JSONDecoder().decode([String: ModelEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveRegistry(_ dict: [String: ModelEntry]) throws {
        let data = try JSONEncoder().encode(dict)
        try data.write(to: registryURL, options: .atomic)
    }

    // MARK: - Queries

    func allModels() -> [ModelEntry] {
        Array(loadRegistry().values).sorted { $0.modelId < $1.modelId }
    }

    func isInstalled(_ modelId: String) -> Bool {
        guard let entry = loadRegistry()[modelId] else { return false }
        let url = modelsDirectory.appendingPathComponent(entry.fileName)
        return fileManager.fileExists(atPath: url.path)
    }

    func localURL(for modelId: String) -> URL? {
        guard let entry = loadRegistry()[modelId] else { return nil }
        let url = modelsDirectory.appendingPathComponent(entry.fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Mutations

    func markInstalled(modelId: String, entry: ModelEntry) throws {
        var dict = loadRegistry()
        dict[modelId] = entry
        try saveRegistry(dict)
    }

    func markUninstalled(_ modelId: String) throws {
        var dict = loadRegistry()
        if let entry = dict[modelId] {
            let url = modelsDirectory.appendingPathComponent(entry.fileName)
            try? fileManager.removeItem(at: url)
        }
        dict[modelId] = nil
        try saveRegistry(dict)
    }

    func setActive(_ modelId: String, active: Bool) throws {
        var dict = loadRegistry()
        dict[modelId]?.isActive = active
        try saveRegistry(dict)
    }

    func modelDirectory() -> URL {
        modelsDirectory
    }
}
