import Foundation
import UniformTypeIdentifiers

final class ImportRouter {
    private let importers: [any FormatImporter]

    init(importers: [any FormatImporter]) {
        self.importers = importers
    }

    func importer(for url: URL) -> (any FormatImporter)? {
        importers.first { $0.canRead(url: url) }
    }

    func importer(for data: Data) -> (any FormatImporter)? {
        importers.first { $0.canRead(data: data) }
    }

    func allImporters() -> [any FormatImporter] {
        importers
    }

    func allUTTypes() -> [UTType] {
        importers.flatMap(\.supportedUTTypes)
    }
}
