import Foundation
import OSLog
import UniformTypeIdentifiers

final class ImportRouter {
    private let importers: [any FormatImporter]

    init(importers: [any FormatImporter]) {
        self.importers = importers.sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
    }

    func importer(for url: URL) -> (any FormatImporter)? {
        guard let importer = importers.first(where: { $0.canRead(url: url) }) else {
            AppLog.general.debug("No importer found for URL: \(url) (pathExtension: \(url.pathExtension))")
            return nil
        }
        return importer
    }

    func importer(for data: Data) -> (any FormatImporter)? {
        guard let importer = importers.first(where: { $0.canRead(data: data) }) else {
            AppLog.general.debug("No importer found for data (\(data.count) bytes)")
            return nil
        }
        return importer
    }

    func allImporters() -> [any FormatImporter] {
        importers
    }

    func allUTTypes() -> [UTType] {
        importers.flatMap(\.supportedUTTypes)
    }
}
