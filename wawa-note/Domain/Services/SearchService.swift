import CoreSpotlight
import Foundation
import WawaNoteCore

struct SearchResult: Identifiable {
  let id = UUID()
  let itemID: UUID
  let matchedField: SearchField
  let snippet: String
  let score: Double  // 0–1 relevance score

  enum SearchField: String {
    case title
    case bodyText
    case transcript
    case analysis
  }
}

/// Context signals used to boost search relevance.
struct SearchContext {
  /// Boost items captured at or near this location.
  var locationName: String?
  /// Boost items captured around this calendar event.
  var calendarEventTitle: String?
  /// Boost items created within this time window.
  var temporalWindow: TimeInterval?  // seconds from reference date
  /// Reference date for recency boost.
  var referenceDate: Date
  /// Boost items in this project.
  var projectID: UUID?

  init(referenceDate: Date = Date()) {
    self.referenceDate = referenceDate
  }
}

final class SearchService {
  private let fileStore: FileArtifactStore
  private let minQueryLength = 2

  // Scoring weights
  private let titleWeight = 0.35
  private let bodyWeight = 0.25
  private let transcriptWeight = 0.25
  private let analysisWeight = 0.15

  // Context boost weights (additive, capped at 0.3 total)
  private let locationBoost = 0.15
  private let calendarBoost = 0.10
  private let recencyBoost = 0.05

  init(fileStore: FileArtifactStore = FileArtifactStore()) {
    self.fileStore = fileStore
  }

  // MARK: - Public API

  func searchNow(query: String, in items: [KnowledgeItem]) -> [SearchResult] {
    searchNow(query: query, in: items, context: nil)
  }

  func searchNow(
    query: String, in items: [KnowledgeItem], context: SearchContext?
  ) -> [SearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minQueryLength else { return [] }

    var results: [SearchResult] = []
    for item in items {
      let itemResults = searchItem(item, query: trimmed)
      for var result in itemResults {
        result = applyContextBoosts(to: result, item: item, context: context)
        results.append(result)
      }
    }

    // Deduplicate by itemID, keeping the best score per item
    var bestPerItem: [UUID: SearchResult] = [:]
    for r in results {
      if let existing = bestPerItem[r.itemID] {
        if r.score > existing.score {
          bestPerItem[r.itemID] = r
        }
      } else {
        bestPerItem[r.itemID] = r
      }
    }

    return bestPerItem.values.sorted { $0.score > $1.score }
  }

  // MARK: - Private search

  private func searchItem(_ item: KnowledgeItem, query: String) -> [SearchResult] {
    var results: [SearchResult] = []

    if let snippet = match(in: item.title, query: query, maxLength: 60) {
      results.append(
        SearchResult(
          itemID: item.id, matchedField: .title, snippet: snippet, score: titleWeight))
    }

    if let body = item.bodyText, let snippet = match(in: body, query: query, maxLength: 120) {
      results.append(
        SearchResult(
          itemID: item.id, matchedField: .bodyText, snippet: snippet, score: bodyWeight))
    }

    if let transcript = try? fileStore.readArtifact(
      Transcript.self, fileName: "transcript.json", meetingId: item.id)
    {
      let fullText = transcript.segments.map(\.text).joined(separator: " ")
      if let snippet = match(in: fullText, query: query, maxLength: 120) {
        results.append(
          SearchResult(
            itemID: item.id, matchedField: .transcript, snippet: snippet,
            score: transcriptWeight))
      }
    }

    if let analysis = try? fileStore.readArtifact(
      MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)
    {
      let analysisText = [analysis.shortSummary, analysis.detailedSummary].compactMap { $0 }.joined(
        separator: " ")
      if let snippet = match(in: analysisText, query: query, maxLength: 120) {
        results.append(
          SearchResult(
            itemID: item.id, matchedField: .analysis, snippet: snippet,
            score: analysisWeight))
      }
    }

    return results
  }

  // MARK: - Context-aware boosting

  private func applyContextBoosts(
    to result: SearchResult, item: KnowledgeItem, context: SearchContext?
  ) -> SearchResult {
    guard let context else { return result }

    var boost: Double = 0

    // Location match — same place
    if let ctxLocation = context.locationName,
      let itemLocation = item.contextPlaceName,
      itemLocation.localizedCaseInsensitiveContains(ctxLocation)
        || ctxLocation.localizedCaseInsensitiveContains(itemLocation)
    {
      boost += locationBoost
    }

    // Calendar match — same event title
    if let ctxEvent = context.calendarEventTitle,
      let itemEvent = item.contextCalendarEventTitle,
      itemEvent.localizedCaseInsensitiveContains(ctxEvent)
        || ctxEvent.localizedCaseInsensitiveContains(itemEvent)
    {
      boost += calendarBoost
    }

    // Calendar event ID match (strong signal — exact same event)
    if context.calendarEventTitle != nil,
      item.calendarEventIdentifier != nil
    {
      // Item was matched to a calendar event — slightly higher relevance
      boost += calendarBoost * 0.5
    }

    // Temporal proximity — items created close together
    if let window = context.temporalWindow {
      let delta = abs(item.createdAt.timeIntervalSince(context.referenceDate))
      if delta < window {
        // Closer = higher boost, up to recencyBoost
        boost += recencyBoost * (1.0 - delta / window)
      }
    }

    // Project match
    if let ctxProjectID = context.projectID,
      item.projectID == ctxProjectID
    {
      boost += 0.05
    }

    // Clamp boost to 0–0.3 range
    let clampedBoost = min(0.3, max(0, boost))

    return SearchResult(
      itemID: result.itemID,
      matchedField: result.matchedField,
      snippet: result.snippet,
      score: min(1.0, result.score + clampedBoost)
    )
  }

  /// Builds a SearchContext from a KnowledgeItem — useful for
  /// "find similar items" queries by the AI agent.
  func contextFromItem(_ item: KnowledgeItem) -> SearchContext {
    var ctx = SearchContext(referenceDate: item.createdAt)
    ctx.locationName = item.contextPlaceName
    ctx.calendarEventTitle = item.contextCalendarEventTitle
    ctx.projectID = item.projectID
    ctx.temporalWindow = 3600  // 1 hour
    return ctx
  }

  // MARK: - Text matching

  private func match(in text: String, query: String, maxLength: Int) -> String? {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    guard let range = text.range(of: query, options: options) else { return nil }

    let start =
      text.index(
        range.lowerBound,
        offsetBy: -min(20, text.distance(from: text.startIndex, to: range.lowerBound)),
        limitedBy: text.startIndex) ?? text.startIndex
    let end =
      text.index(
        range.upperBound,
        offsetBy: min(maxLength - 20, text.distance(from: range.upperBound, to: text.endIndex)),
        limitedBy: text.endIndex) ?? text.endIndex

    var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    if start != text.startIndex { snippet = "..." + snippet }
    if end != text.endIndex { snippet = snippet + "..." }
    return snippet
  }
}

// MARK: - Core Spotlight Indexing

final class SpotlightIndexService {
  private let index = CSSearchableIndex.default()

  func indexItem(_ item: KnowledgeItem) {
    let attrs = CSSearchableItemAttributeSet(contentType: .text)
    attrs.title = item.title
    attrs.contentDescription = item.bodyText.map { String($0.prefix(300)) }
    attrs.keywords = item.tags
    attrs.addedDate = item.createdAt

    let searchableItem = CSSearchableItem(
      uniqueIdentifier: item.id.uuidString,
      domainIdentifier: "com.wawa-note.knowledge",
      attributeSet: attrs
    )
    index.indexSearchableItems([searchableItem]) { error in
      if let error { AppLog.general.warning("Spotlight index failed: \(error)") }
    }
  }

  func deleteItem(_ itemID: UUID) {
    index.deleteSearchableItems(withIdentifiers: [itemID.uuidString]) { error in
      if let error { AppLog.general.warning("Spotlight delete failed: \(error)") }
    }
  }
}
