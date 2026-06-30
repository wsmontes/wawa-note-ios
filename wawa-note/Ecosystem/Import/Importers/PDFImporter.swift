import Foundation
import PDFKit
import UniformTypeIdentifiers

struct PDFImporter: FormatImporter {
  let formatIdentifier = "pdf"
  let displayName = "PDF Document"
  let supportedUTTypes: [UTType] = [.pdf]

  func canRead(url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
  func canRead(data: Data) -> Bool {
    data.prefix(4).map { String(format: "%c", $0) }.joined() == "%PDF"
  }

  func importFromURL(_ url: URL) async throws -> ImportResult {
    guard let pdf = PDFDocument(url: url) else {
      throw NSError(
        domain: "PDFImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read PDF"])
    }

    var fullText = ""
    for i in 0..<pdf.pageCount {
      if let page = pdf.page(at: i), let text = page.string {
        fullText += text + "\n"
      }
    }

    let title =
      pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
      ?? url.deletingPathExtension().lastPathComponent

    let item = KnowledgeItem(
      type: .note,
      title: title,
      status: .draft,
      bodyText: fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    item.isImported = true
    item.importSourceURL = url.lastPathComponent

    let pages = pdf.pageCount
    let warnings: [String] = pages == 0 ? ["No text extracted from PDF"] : []

    return ImportResult(knowledgeItem: item, artifacts: [:], warnings: warnings)
  }
}
