import Foundation
import CoreSpotlight
// Related JIRA: KAN-142


struct SearchResult: Identifiable {
    let id = UUID()
    let itemID: UUID
    let matchedField: SearchField
    let snippet: String

    enum SearchField: String {
        case title
        case bodyText
        case transcript
        case analysis
    }
}

final class SearchService {
    private let fileStore: FileArtifactStore
    private let minQueryLength = 2

    init(fileStore: FileArtifactStore = FileArtifactStore()) {
        self.fileStore = fileStore
    }

    func searchNow(query: String, in items: [KnowledgeItem]) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minQueryLength else { return [] }

        var results: [SearchResult] = []
        for item in items {
            results.append(contentsOf: searchItem(item, query: trimmed))
        }
        return results
    }

    // MARK: - Private

    private func searchItem(_ item: KnowledgeItem, query: String) -> [SearchResult] {
        var results: [SearchResult] = []

        if let snippet = match(in: item.title, query: query, maxLength: 60) {
            results.append(SearchResult(itemID: item.id, matchedField: .title, snippet: snippet))
        }

        if let body = item.bodyText, let snippet = match(in: body, query: query, maxLength: 120) {
            results.append(SearchResult(itemID: item.id, matchedField: .bodyText, snippet: snippet))
        }

        // Search transcript and analysis if they exist — capability-based, not type-based
        if let transcript = try? fileStore.readArtifact(Transcript.self, fileName: "transcript.json", meetingId: item.id) {
            let fullText = transcript.segments.map(\.text).joined(separator: " ")
            if let snippet = match(in: fullText, query: query, maxLength: 120) {
                results.append(SearchResult(itemID: item.id, matchedField: .transcript, snippet: snippet))
            }
        }

        if let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) {
            let analysisText = [analysis.shortSummary, analysis.detailedSummary].compactMap { $0 }.joined(separator: " ")
            if let snippet = match(in: analysisText, query: query, maxLength: 120) {
                results.append(SearchResult(itemID: item.id, matchedField: .analysis, snippet: snippet))
            }
        }

        return results
    }

    private func match(in text: String, query: String, maxLength: Int) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let range = text.range(of: query, options: options) else { return nil }

        let start = text.index(range.lowerBound, offsetBy: -min(20, text.distance(from: text.startIndex, to: range.lowerBound)), limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: min(maxLength - 20, text.distance(from: range.upperBound, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex

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
