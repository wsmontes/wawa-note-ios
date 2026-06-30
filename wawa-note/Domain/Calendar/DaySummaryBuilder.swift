import Foundation
import SwiftData
import WawaNoteCore

struct DaySummary {
  let date: Date
  var itemCounts: [KnowledgeItemType: Int]
  var hasOnThisDay: Bool
  var journalMood: String?

  var totalItems: Int { itemCounts.values.reduce(0, +) }

  func dots(count: Int) -> [KnowledgeItemType] {
    itemCounts
      .sorted { $0.value > $1.value }
      .prefix(count)
      .map(\.key)
  }
}

@MainActor
final class DaySummaryBuilder {
  private let onThisDayService: OnThisDayService

  init(context: ModelContext) {
    self.onThisDayService = OnThisDayService(context: context)
  }

  func build(for month: Date, items: [KnowledgeItem]) -> [Date: DaySummary] {
    let cal = Calendar.current
    var result: [Date: DaySummary] = [:]

    for item in items {
      let day = cal.startOfDay(for: item.scheduledDate ?? item.createdAt)
      var summary =
        result[day]
        ?? DaySummary(
          date: day,
          itemCounts: [:],
          hasOnThisDay: false,
          journalMood: nil
        )

      summary.itemCounts[item.type, default: 0] += 1

      // Extract journal mood from tags
      if item.type == .journalEntry, let moodTag = TimelineEntry.extractMood(from: item.tags) {
        summary.journalMood = moodTag
      }

      result[day] = summary
    }

    // Mark days that have on-this-day entries
    for (day, var summary) in result {
      let onThisDayEntries = onThisDayService.entries(for: day)
      summary.hasOnThisDay = !onThisDayEntries.isEmpty
      result[day] = summary
    }

    return result
  }
}
