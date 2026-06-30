import Foundation
import SwiftData

// Related JIRA: KAN-54, KAN-144

@MainActor
final class OnThisDayService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func entries(for date: Date) -> [TimelineEntry] {
        let cal = Calendar.current
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)
        let currentYear = cal.component(.year, from: date)

        var allItems: [KnowledgeItem] = []
        do {
            var descriptor = FetchDescriptor<KnowledgeItem>()
            descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
            allItems = try context.fetch(descriptor)
        } catch {
            return []
        }

        return
            allItems
            .filter { item in
                let itemYear = cal.component(.year, from: item.createdAt)
                let itemMonth = cal.component(.month, from: item.createdAt)
                let itemDay = cal.component(.day, from: item.createdAt)
                return itemMonth == month && itemDay == day && itemYear != currentYear
            }
            .map { TimelineEntry(item: $0) }
    }
}
