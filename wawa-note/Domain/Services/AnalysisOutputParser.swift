import Foundation

// MARK: - AnalysisOutput

struct AnalysisOutput {
    let summary: String?
    let decisions: [DecisionItem]
    let actionItems: [ActionItem]
    let risks: [RiskItem]
    let openQuestions: [String]
    let peopleMentioned: [String]
    let topicsDiscussed: [String]
    let keyPoints: [String]

    struct DecisionItem {
        let decision: String
        let context: String?
        let owner: String?
    }

    struct ActionItem {
        let task: String
        let owner: String?
        let deadline: String?
    }

    struct RiskItem {
        let risk: String
        let mitigation: String?
    }

    var hasActionableContent: Bool {
        !decisions.isEmpty || !actionItems.isEmpty || !risks.isEmpty || !openQuestions.isEmpty
    }
}

// MARK: - AnalysisOutputParser

struct AnalysisOutputParser {
    /// Parse analysis.json for a given item.
    /// Returns nil if no analysis file exists or parsing fails.
    static func parse(item: KnowledgeItem, fileStore: FileArtifactStore) -> AnalysisOutput? {
        let itemDir = fileStore.itemDirectoryURL(for: item.id)
        let analysisURL = itemDir.appendingPathComponent("analysis.json")
        guard let data = try? Data(contentsOf: analysisURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return AnalysisOutput(
            summary: json["summary"] as? String,
            decisions: parseDecisions(from: json),
            actionItems: parseActionItems(from: json),
            risks: parseRisks(from: json),
            openQuestions: json["open_questions"] as? [String] ?? [],
            peopleMentioned: json["people_mentioned"] as? [String] ?? [],
            topicsDiscussed: json["topics_discussed"] as? [String] ?? [],
            keyPoints: json["key_points"] as? [String] ?? []
        )
    }

    private static func parseDecisions(from json: [String: Any]) -> [AnalysisOutput.DecisionItem] {
        guard let items = json["decisions"] as? [[String: Any]] else { return [] }
        return items.compactMap { dict in
            guard let decision = dict["decision"] as? String else { return nil }
            return AnalysisOutput.DecisionItem(
                decision: decision,
                context: dict["context"] as? String,
                owner: dict["owner"] as? String
            )
        }
    }

    private static func parseActionItems(from json: [String: Any]) -> [AnalysisOutput.ActionItem] {
        guard let items = json["action_items"] as? [[String: Any]] else { return [] }
        return items.compactMap { dict in
            guard let task = dict["task"] as? String else { return nil }
            return AnalysisOutput.ActionItem(
                task: task,
                owner: dict["owner"] as? String,
                deadline: dict["deadline"] as? String
            )
        }
    }

    private static func parseRisks(from json: [String: Any]) -> [AnalysisOutput.RiskItem] {
        guard let items = json["risks"] as? [[String: Any]] else { return [] }
        return items.compactMap { dict in
            guard let risk = dict["risk"] as? String else { return nil }
            return AnalysisOutput.RiskItem(
                risk: risk,
                mitigation: dict["mitigation"] as? String
            )
        }
    }
}
