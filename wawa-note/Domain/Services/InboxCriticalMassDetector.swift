import Foundation
import SwiftData

// Related JIRA: KAN-10, KAN-49

@MainActor
final class InboxCriticalMassDetector {
    private let context: ModelContext
    private let threshold = 3

    init(context: ModelContext) {
        self.context = context
    }

    /// Check if there are enough orphan items to suggest project creation.
    /// Returns the orphan items if threshold is met, nil otherwise.
    func checkAndSuggest() -> [KnowledgeItem]? {
        let orphanItems = fetchOrphanItems()
        guard orphanItems.count >= threshold else { return nil }

        let suggestionSvc = ProjectSuggestionService(context: context)

        // Dedup: check if suggestion already exists
        let descriptor = FetchDescriptor<ProjectSuggestion>(
            predicate: #Predicate { $0.suggestionTypeRaw == "projectCreation" }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        if !existing.isEmpty { return nil }

        let titles = orphanItems.prefix(5).map { "• \($0.title)" }.joined(separator: "\n")
        suggestionSvc.emit(
            projectID: orphanItems.first?.id ?? UUID(),
            title: "You have \(orphanItems.count) unassigned items",
            body: "These look related. Create a project to organize them?\n\n\(titles)",
            type: .projectCreation
        )
        return orphanItems
    }

    private func fetchOrphanItems() -> [KnowledgeItem] {
        let descriptor = FetchDescriptor<KnowledgeItem>(
            predicate: #Predicate { $0.projectID == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
