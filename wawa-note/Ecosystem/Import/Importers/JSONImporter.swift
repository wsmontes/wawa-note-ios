import Foundation
import UniformTypeIdentifiers
import WawaNoteCore

final class JSONImporter: FormatImporter, @unchecked Sendable {
  let formatIdentifier = "json"
  let displayName = "Wawa Note JSON"
  let supportedUTTypes: [UTType] = [.json]

  func canRead(url: URL) -> Bool {
    url.pathExtension.lowercased() == "json"
  }

  func canRead(data: Data) -> Bool {
    if let str = String(data: data.prefix(100), encoding: .utf8) {
      return str.trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }
    return false
  }

  func importFromURL(_ url: URL) async throws -> ImportResult {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()

    struct ImportJSON: Codable {
      let version: String?
      let schema: String?
      let exportedAt: String?
      let item: ImportItem?
      let meeting: ImportMeeting?

      struct ImportItem: Codable {
        let id: String?
        let type: String?
        let title: String?
        let createdAt: String?
        let tags: [String]?
        let durationSeconds: Double?
        let languageCode: String?
        let body: String?
        let summary: String?
      }

      struct ImportMeeting: Codable {
        let title: String?
        let createdAt: String?
        let durationSeconds: Double?
        let status: String?
        let tags: [String]?
        let body: String?
        let summary: String?
        let transcript: String?
      }
    }

    let imported = try decoder.decode(ImportJSON.self, from: data)

    let dateStr = imported.item?.createdAt ?? imported.meeting?.createdAt ?? ""
    let createdAt = ISO8601DateFormatter().date(from: dateStr) ?? Date()

    let itemType = KnowledgeItemType(rawValue: imported.item?.type ?? "audio") ?? .audio

    let bodyText =
      imported.item?.body ?? imported.item?.summary
      ?? imported.meeting?.body ?? imported.meeting?.summary

    let item = KnowledgeItem(
      type: itemType,
      title: imported.item?.title ?? imported.meeting?.title
        ?? url.deletingPathExtension().lastPathComponent,
      createdAt: createdAt,
      updatedAt: createdAt,
      status: .recorded,
      tags: imported.item?.tags ?? imported.meeting?.tags ?? [],
      durationSeconds: imported.item?.durationSeconds ?? imported.meeting?.durationSeconds,
      languageCode: imported.item?.languageCode
    )
    item.bodyText = bodyText

    item.isImported = true
    item.importSourceURL = url.absoluteString

    var warnings: [String] = []
    if imported.version == nil {
      warnings.append("No version field in JSON")
    }

    return ImportResult(knowledgeItem: item, artifacts: [:], warnings: warnings)
  }
}
