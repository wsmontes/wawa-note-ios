import Foundation
import SwiftData
import WawaNoteCore

@MainActor
final class OnThisDayService {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func entries(for date: Date) -> [TimelineEntry] {
    var allItems: [KnowledgeItem] = []
    do {
      var descriptor = FetchDescriptor<KnowledgeItem>()
      descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
      allItems = try context.fetch(descriptor)
    } catch {
      return []
    }
    return Self.filterEntries(from: allItems, for: date)
  }

  /// Bulk version: filters pre-fetched items for a date. Use this when
  /// computing entries for multiple days to avoid repeated full-table scans.
  static func filterEntries(from items: [KnowledgeItem], for date: Date) -> [TimelineEntry] {
    let cal = Calendar.current
    let month = cal.component(.month, from: date)
    let day = cal.component(.day, from: date)
    let currentYear = cal.component(.year, from: date)

    return
      items
      .filter { item in
        let itemYear = cal.component(.year, from: item.createdAt)
        let itemMonth = cal.component(.month, from: item.createdAt)
        let itemDay = cal.component(.day, from: item.createdAt)
        return itemMonth == month && itemDay == day && itemYear != currentYear
      }
      .map { TimelineEntry(item: $0) }
  }
}
