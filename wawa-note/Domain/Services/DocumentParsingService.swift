import Foundation
import PDFKit
import SwiftData
// Related JIRA: KAN-7, KAN-26


/// Extracted from ContentPipelineService — handles document parsing (PDF, CSV, Word/RTF, file listing).
struct DocumentParsingService {
    private let fileStore: FileArtifactStore

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
    }

    // MARK: Document I/O

    func readPDF(_ itemId: String) -> String? {
        guard let uuid = UUID(uuidString: itemId) else { return nil }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        let pdfs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension.lowercased() == "pdf"
        } ?? []
        guard let pdfURL = pdfs.first,
              let pdf = PDFDocument(url: pdfURL) else { return nil }
        return pdf.string
    }

    func readExcel(_ itemId: String, context: ModelContext) -> [[String: Any]]? {
        guard let uuid = UUID(uuidString: itemId),
              let item = try? context.fetch(FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == uuid })).first,
              let text = item.bodyText ?? loadFileText(itemId: itemId, ext: "csv") else { return nil }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let headers = lines[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.dropFirst().map { line in
            let cells = line.components(separatedBy: ",")
            var row: [String: Any] = [:]
            for (i, h) in headers.enumerated() {
                row[h] = i < cells.count ? cells[i].trimmingCharacters(in: .whitespaces) : ""
            }
            return row
        }
    }

    func readWord(_ itemId: String) -> String? {
        guard let uuid = UUID(uuidString: itemId) else { return nil }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        let docs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "docx" || ext == "rtf" || ext == "txt"
        } ?? []
        guard let docURL = docs.first else { return nil }
        if docURL.pathExtension.lowercased() == "txt" {
            return try? String(contentsOf: docURL, encoding: .utf8)
        }
        if let rtf = try? NSAttributedString(url: docURL, options: [:], documentAttributes: nil) {
            return rtf.string
        }
        return try? String(contentsOf: docURL, encoding: .utf8)
    }

    func listFiles(_ itemId: String) -> [String] {
        guard let uuid = UUID(uuidString: itemId) else { return [] }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.map { $0.lastPathComponent } ?? []
    }

    func loadFileText(itemId: String, ext: String) -> String? {
        guard let uuid = UUID(uuidString: itemId) else { return nil }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension.lowercased() == ext
        } ?? []
        guard let url = files.first else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Chart data

    func chartData(_ data: [[String: Any]], type: String, labels: [String]) -> [String: Any] {
        return ["type": type, "labels": labels, "data": data]
    }
}
