import Foundation
import SwiftData

// MARK: - DerivationResult

struct DerivationResult {
    var tasksCreated = 0
    var decisionsCreated = 0
    var risksCreated = 0
    var questionsCreated = 0
    var isEmpty: Bool { tasksCreated == 0 && decisionsCreated == 0 && risksCreated == 0 && questionsCreated == 0 }
}

// MARK: - DerivationService

@MainActor
final class DerivationService {
    private let context: ModelContext
    private let derivedService: ProjectDerivedItemService

    init(context: ModelContext, derivedService: ProjectDerivedItemService) {
        self.context = context
        self.derivedService = derivedService
    }

    /// Convert analysis output into ProjectDerivedItems.
    /// Returns counts of what was created for UI feedback.
    func derive(from output: AnalysisOutput, projectID: UUID, sourceItemID: UUID) -> DerivationResult {
        var result = DerivationResult()

        // Action items → Tasks (in Kanban)
        for action in output.actionItems {
            do {
                let taskBody = TaskBody(
                    description: action.task,
                    sourceSegmentIDs: [],
                    aiGenerated: true,
                    suggestedByItemID: sourceItemID
                )
                let bodyData = try? JSONEncoder().encode(taskBody)
                let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }
                _ = try derivedService.createTask(
                    title: action.task,
                    projectID: projectID,
                    sourceItemID: sourceItemID,
                    ownerName: action.owner,
                    dueAt: action.deadline.flatMap { ISO8601DateFormatter().date(from: $0) },
                    bodyJSON: bodyStr
                )
                result.tasksCreated += 1
            } catch {
                AppLog.provider.error("Derivation: failed to create task '\(action.task)': \(error)")
            }
        }

        // Decisions → ProjectDerivedItem.decision
        for decision in output.decisions {
            let body: [String: String] = [
                "decision": decision.decision,
                "context": decision.context ?? "",
                "owner": decision.owner ?? "",
                "status": "pending"
            ]
            let bodyData = try? JSONEncoder().encode(body)
            let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }
            let item = ProjectDerivedItem(
                projectID: projectID,
                sourceItemID: sourceItemID,
                type: .decision,
                title: decision.decision,
                bodyJSON: bodyStr
            )
            context.insert(item)
            result.decisionsCreated += 1
        }

        // Risks → ProjectDerivedItem.signal
        for risk in output.risks {
            do {
                let signalBody = SignalBody(
                    signalType: "risk",
                    description: risk.risk,
                    suggestedAction: risk.mitigation,
                    relatedItemIDs: [sourceItemID],
                    impactScore: 0.5,
                    urgencyScore: 0.5
                )
                _ = try derivedService.createSignal(
                    title: "Risk: \(risk.risk)",
                    projectID: projectID,
                    sourceItemID: sourceItemID,
                    signalBody: signalBody
                )
                result.risksCreated += 1
            } catch {
                AppLog.provider.error("Derivation: failed to create signal for risk '\(risk.risk)': \(error)")
            }
        }

        // Open questions → ProjectDerivedItem.question
        for question in output.openQuestions {
            let body: [String: String] = [
                "question": question,
                "status": "open"
            ]
            let bodyData = try? JSONEncoder().encode(body)
            let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) }
            let item = ProjectDerivedItem(
                projectID: projectID,
                sourceItemID: sourceItemID,
                type: .question,
                title: question,
                bodyJSON: bodyStr
            )
            context.insert(item)
            result.questionsCreated += 1
        }

        try? context.save()
        return result
    }
}
