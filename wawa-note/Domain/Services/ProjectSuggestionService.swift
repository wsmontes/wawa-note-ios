import Foundation
import SwiftData

@MainActor
final class ProjectSuggestionService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Create a new pending suggestion. Deduplicates — if a similar pending
    /// suggestion exists for the same project+type, skips creation.
    func emit(
        projectID: UUID,
        title: String,
        body: String,
        type: SuggestionType,
        proposedFields: ProjectUpdateFields? = nil
    ) {
        let typeRaw = type.rawValue
        let pendingRaw = SuggestionStatus.pending.rawValue
        let existing = try? context.fetch(
            FetchDescriptor<ProjectSuggestion>(
                predicate: #Predicate {
                    $0.projectID == projectID &&
                    $0.suggestionTypeRaw == typeRaw &&
                    $0.statusRaw == pendingRaw
                }
            )
        )
        if let existing, !existing.isEmpty { return }

        let suggestion = ProjectSuggestion(
            projectID: projectID,
            title: title,
            body: body,
            suggestionType: type,
            proposedFields: proposedFields
        )
        context.insert(suggestion)
        try? context.save()
    }

    /// Accept a suggestion — apply its proposed fields and mark as accepted.
    func accept(_ suggestion: ProjectSuggestion) throws {
        if let json = suggestion.proposedFieldsJSON,
           let data = json.data(using: .utf8),
           let fields = try? JSONDecoder().decode(ProjectUpdateFields.self, from: data) {
            _ = try ProjectService(context: context).update(
                id: suggestion.projectID,
                fields: fields,
                origin: .llm,
                reason: "accepted suggestion: \(suggestion.title)"
            )
        }
        suggestion.status = .accepted
        suggestion.resolvedAt = Date()
        try context.save()
    }

    /// Dismiss a suggestion without applying its changes.
    func dismiss(_ suggestion: ProjectSuggestion) throws {
        suggestion.status = .dismissed
        suggestion.resolvedAt = Date()
        try context.save()
    }

    /// Fetch pending suggestions for a project, ordered by recency.
    func pending(for projectID: UUID, limit: Int = 2) -> [ProjectSuggestion] {
        let pendingRaw = SuggestionStatus.pending.rawValue
        let descriptor = FetchDescriptor<ProjectSuggestion>(
            predicate: #Predicate {
                $0.projectID == projectID &&
                $0.statusRaw == pendingRaw
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let results = (try? context.fetch(descriptor)) ?? []
        return Array(results.prefix(limit))
    }

    /// Expire suggestions older than 7 days that are still pending.
    func expireOldSuggestions() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let pendingRaw = SuggestionStatus.pending.rawValue
        let descriptor = FetchDescriptor<ProjectSuggestion>(
            predicate: #Predicate {
                $0.statusRaw == pendingRaw &&
                $0.createdAt < cutoff
            }
        )
        guard let expired = try? context.fetch(descriptor) else { return }
        for suggestion in expired {
            suggestion.status = .dismissed
            suggestion.resolvedAt = Date()
        }
        try? context.save()
    }
}
