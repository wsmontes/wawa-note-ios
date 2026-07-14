import Foundation
import SwiftData
import WawaNoteCore

// Related JIRA: KAN-XX

/// Extracts text from notes, bookmarks, and imported documents.
final class TextProcessor: ContentProcessor {

  func extract(from item: KnowledgeItem, context: ModelContext) async -> String? {
    guard !Task.isCancelled else {
      fail(item, context: context, error: .taskCancelled)
      return nil
    }

    // Use existing bodyText if available
    if let body = item.bodyText, !body.isEmpty, body != " " {
      return body
    }

    // Fetch web bookmark content
    if item.type == .webBookmark, let urlStr = item.importSourceURL, let url = URL(string: urlStr),
      let scheme = url.scheme, scheme.hasPrefix("http")
    {
      do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else {
          fail(item, context: context, error: .bookmarkFetchFailed)
          return nil
        }
        let plainText =
          html
          .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
          .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
          .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = String(plainText.prefix(8000))
        item.bodyText = truncated
        context.safeSave(context: "bookmark-extract-success", itemId: item.id)
        return truncated
      } catch {
        fail(item, context: context, error: .bookmarkFetchFailed)
        return nil
      }
    }

    fail(item, context: context, error: .textEmpty)
    return nil
  }

  private func fail(_ item: KnowledgeItem, context: ModelContext, error: ExtractionError) {
    item.status = .failed
    item.lastErrorRaw = error.errorDescription
    context.safeSave(context: "text-extraction-failed", itemId: item.id)
  }
}
