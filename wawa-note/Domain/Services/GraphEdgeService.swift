import Foundation
import SwiftData

@MainActor
final class GraphEdgeService {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func create(
    fromID: UUID,
    toID: UUID,
    edgeType: EdgeType,
    weight: Double = 1.0,
    provenanceItemID: UUID? = nil,
    provenanceSegmentIDs: [String] = []
  ) throws -> GraphEdge {
    // Avoid duplicates
    let existing = try find(fromID: fromID, toID: toID, edgeType: edgeType)
    if let existing {
      existing.weight = max(existing.weight, weight)
      try context.save()
      return existing
    }

    let edge = GraphEdge(
      fromID: fromID,
      toID: toID,
      edgeType: edgeType,
      weight: weight,
      provenanceItemID: provenanceItemID,
      provenanceSegmentIDs: provenanceSegmentIDs
    )
    context.insert(edge)
    try context.save()
    return edge
  }

  func find(fromID: UUID, toID: UUID, edgeType: EdgeType) throws -> GraphEdge? {
    let typeRaw = edgeType.rawValue
    var descriptor = FetchDescriptor<GraphEdge>(
      predicate: #Predicate { $0.fromID == fromID && $0.toID == toID && $0.edgeTypeRaw == typeRaw }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  func edges(from nodeID: UUID) throws -> [GraphEdge] {
    var descriptor = FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.fromID == nodeID })
    descriptor.sortBy = [SortDescriptor(\.weight, order: .reverse)]
    return try context.fetch(descriptor)
  }

  func edges(to nodeID: UUID) throws -> [GraphEdge] {
    var descriptor = FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.toID == nodeID })
    descriptor.sortBy = [SortDescriptor(\.weight, order: .reverse)]
    return try context.fetch(descriptor)
  }

  func neighborhood(of nodeID: UUID, radius: Int = 1) throws -> [GraphEdge] {
    var allEdges: [GraphEdge] = []
    var visited: Set<UUID> = [nodeID]
    var frontier: Set<UUID> = [nodeID]

    for _ in 0..<radius {
      var nextFrontier: Set<UUID> = []
      for node in frontier {
        let outgoing = try edges(from: node)
        let incoming = try edges(to: node)
        allEdges.append(contentsOf: outgoing)
        allEdges.append(contentsOf: incoming)
        for edge in outgoing { if !visited.contains(edge.toID) { nextFrontier.insert(edge.toID) } }
        for edge in incoming {
          if !visited.contains(edge.fromID) { nextFrontier.insert(edge.fromID) }
        }
      }
      visited.formUnion(nextFrontier)
      frontier = nextFrontier
    }
    return allEdges
  }

  func edges(ofType edgeType: EdgeType) throws -> [GraphEdge] {
    let typeRaw = edgeType.rawValue
    var descriptor = FetchDescriptor<GraphEdge>(predicate: #Predicate { $0.edgeTypeRaw == typeRaw })
    descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
    return try context.fetch(descriptor)
  }

  /// Increase weight on the strongest edge between two nodes (any type).
  /// Used to persist edge reinforcements from project ingestion.
  func reinforce(fromID: UUID, toID: UUID) throws {
    // Find all edges between these nodes, reinforce the one with highest weight
    let fromTypeRaw = EdgeType.relatesTo.rawValue
    var descriptor = FetchDescriptor<GraphEdge>(
      predicate: #Predicate { $0.fromID == fromID && $0.toID == toID }
    )
    descriptor.sortBy = [SortDescriptor(\.weight, order: .reverse)]
    descriptor.fetchLimit = 1
    if let edge = try context.fetch(descriptor).first {
      edge.weight += 0.5
      try context.save()
    }
  }

  func deleteEdge(_ edge: GraphEdge) throws {
    context.delete(edge)
    try context.save()
  }

  func recentEdges(limit: Int = 20) throws -> [GraphEdge] {
    var descriptor = FetchDescriptor<GraphEdge>()
    descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
    descriptor.fetchLimit = limit
    return try context.fetch(descriptor)
  }
}

// MARK: - Graph Hypothesis

struct GraphHypothesis: Identifiable, Codable, Sendable {
  let id: UUID
  var type: HypothesisType
  var text: String
  var sourceItemIDs: [UUID]
  var confidence: Double
  var createdAt: Date

  init(
    id: UUID = UUID(),
    type: HypothesisType,
    text: String,
    sourceItemIDs: [UUID] = [],
    confidence: Double = 0.5,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.type = type
    self.text = text
    self.sourceItemIDs = sourceItemIDs
    self.confidence = confidence
    self.createdAt = createdAt
  }
}

enum HypothesisType: String, Codable, CaseIterable, Sendable {
  case contradiction = "Contradiction"
  case pattern = "Pattern"
  case gap = "Gap"
  case theme = "Emerging Theme"
  case influence = "Influence"

  var icon: String {
    switch self {
    case .contradiction: "arrow.triangle.swap"
    case .pattern: "rectangle.3.group"
    case .gap: "questionmark.diamond"
    case .theme: "lightbulb"
    case .influence: "person.2"
    }
  }

  var color: String {
    switch self {
    case .contradiction: "orange"
    case .pattern: "blue"
    case .gap: "red"
    case .theme: "yellow"
    case .influence: "purple"
    }
  }
}

// MARK: - Graph Intelligence Service

/// Analyzes the project graph to discover hidden patterns, contradictions,
/// gaps, and emerging themes — going beyond simple entity extraction to
/// find what's latent in the data.
@MainActor
final class GraphIntelligenceService {
  private let context: ModelContext
  private let fileStore: FileArtifactStore

  init(context: ModelContext, fileStore: FileArtifactStore = FileArtifactStore()) {
    self.context = context
    self.fileStore = fileStore
  }

  func analyzeGraph(for projectID: UUID) async -> [GraphHypothesis] {
    guard let provider = try? ProviderRouter.resolveActive(context: context) else {
      AppLog.provider.warning("GraphIntelligence: no provider configured")
      return []
    }

    let projSvc = ProjectService(context: context)
    let edgeSvc = GraphEdgeService(context: context)
    let taskSvc = TaskService(context: context)
    guard let project = try? projSvc.fetch(id: projectID) else { return [] }

    let items = (try? projSvc.items(in: projectID)) ?? []
    let tasks = (try? taskSvc.tasks(for: projectID)) ?? []
    let edges = (try? edgeSvc.neighborhood(of: projectID, radius: 3)) ?? []

    guard items.count >= 2 else { return [] }  // Need at least 2 items for cross-item analysis

    let graphDescription = buildGraphDescription(
      project: project, items: items, tasks: tasks, edges: edges)
    let model =
      AutomationSettings.shared.resolveAutoAnalysisModel(context: context)
      ?? AutomationSettings.shared.autoAnalysisModel

    let prompt = """
      You are a graph intelligence analyst. Below is a project's knowledge graph: items, tasks, connections, and entities.

      Your job: find what's HIDDEN in this data. Do not summarize what's obvious. Look for:

      1. CONTRADICTIONS: decisions or action items that conflict across items
      2. PATTERNS: recurring themes, people, risks, or types of decisions
      3. GAPS: questions raised but never answered, decisions promised but not made, topics mentioned in one item but never followed up
      4. EMERGING THEMES: topics that appear across multiple disconnected items — something the project is "about" that isn't explicitly stated
      5. INFLUENCE: who or what drives decisions? Are there key people, recordings, or documents that shape outcomes?

      Return a JSON array. Each hypothesis has: type (contradiction|pattern|gap|theme|influence), text (one clear sentence), confidence (0.0-1.0).

      \(graphDescription)

      Return ONLY: [{"type": "...", "text": "...", "confidence": 0.8}, ...]
      Max 6 hypotheses. If nothing interesting, return [].
      """

    let params = AIConfigService.shared.requestParams(for: "analysis", model: model)

    let request = AIRequest(
      model: model,
      messages: [
        AIMessage(
          role: .system,
          content: [
            .text(
              "You are a graph intelligence analyst. Return only valid JSON arrays. Never invent data — only report what you can infer from the provided graph."
            )
          ]),
        AIMessage(role: .user, content: [.text(prompt)]),
      ],
      temperature: params.temperature,
      maxTokens: params.maxTokens,
      responseFormat: .jsonObject
    )

    do {
      let response = try await provider.send(request)
      return parseHypotheses(response.content)
    } catch {
      AppLog.provider.error("GraphIntelligence: AI call failed: \(error)")
      return []
    }
  }

  private func buildGraphDescription(
    project: Project, items: [KnowledgeItem], tasks: [TaskItem], edges: [GraphEdge]
  ) -> String {
    var desc = "PROJECT: \(project.name)\n"
    if let summary = project.summary, !summary.isEmpty {
      desc += "Summary: \(summary)\n"
    }
    if let instructions = project.customInstructions, !instructions.isEmpty {
      desc += "User focus: \(instructions)\n"
    }
    desc += "\n"

    // Items with their analysis
    desc += "ITEMS (\(items.count)):\n"
    for item in items {
      desc += "- [\(item.type.label)] \(item.title)\n"
      if let analysis = try? fileStore.readArtifact(
        MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id)
      {
        if !analysis.shortSummary.isEmpty { desc += "  Summary: \(analysis.shortSummary)\n" }
        if !analysis.decisions.isEmpty {
          desc += "  Decisions: " + analysis.decisions.map(\.title).joined(separator: "; ") + "\n"
        }
        if !analysis.actionItems.isEmpty {
          desc +=
            "  Actions: "
            + analysis.actionItems.map { "\($0.task) (\($0.owner ?? "?"))" }.joined(separator: "; ")
            + "\n"
        }
        if !analysis.risks.isEmpty {
          desc += "  Risks: " + analysis.risks.map(\.risk).joined(separator: "; ") + "\n"
        }
        if !analysis.entities.isEmpty {
          desc +=
            "  Entities: "
            + analysis.entities.map { "\($0.name)(\($0.type.rawValue))" }.joined(separator: ", ")
            + "\n"
        }
      }
    }
    desc += "\n"

    // Tasks
    if !tasks.isEmpty {
      desc += "TASKS (\(tasks.count)):\n"
      for t in tasks {
        desc += "- [\(t.statusRaw)] \(t.title)"
        if let o = t.ownerName { desc += " | owner: \(o)" }
        desc += "\n"
      }
      desc += "\n"
    }

    // Edges
    if !edges.isEmpty {
      desc += "CONNECTIONS (\(edges.count)):\n"
      for e in edges {
        let from =
          items.first(where: { $0.id == e.fromID })?.title
          ?? e.fromID.uuidString.prefix(8).description
        let to =
          items.first(where: { $0.id == e.toID })?.title ?? e.toID.uuidString.prefix(8).description
        desc += "- \(from) → [\(e.edgeType.rawValue)] → \(to)\n"
      }
    }

    return desc
  }

  private func parseHypotheses(_ json: String) -> [GraphHypothesis] {
    let cleaned = ProviderAdapter.normalizeJSON(json)
    guard let data = cleaned.data(using: .utf8) else { return [] }
    struct RawHypothesis: Decodable {
      var type: String?
      var text: String?
      var confidence: Double?
    }
    do {
      let raw = try JSONDecoder().decode([RawHypothesis].self, from: data)
      return raw.compactMap { h in
        guard let typeStr = h.type, let text = h.text, !text.isEmpty,
          let type = HypothesisType(rawValue: typeStr.capitalized)
            ?? {
              switch typeStr.lowercased() {
              case "contradiction": return .contradiction
              case "pattern": return .pattern
              case "gap": return .gap
              case "theme", "emerging_theme": return .theme
              case "influence": return .influence
              default: return nil
              }
            }()
        else { return nil }
        return GraphHypothesis(type: type, text: text, confidence: h.confidence ?? 0.5)
      }
    } catch {
      AppLog.provider.error("GraphIntelligence: parse failed: \(error)")
      return []
    }
  }
}
