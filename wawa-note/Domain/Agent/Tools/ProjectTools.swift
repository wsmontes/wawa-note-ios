import Foundation
import SwiftData
import WawaNoteCore

/// Tools available to the Project Agent during synthesis.
enum ProjectTools {
  /// Creates all project tools for a given project.
  static func makeTools(projectID: UUID) -> [any AgentTool] {
    [
      SynthesizeProjectTool(projectID: projectID),
      EmitSignalTool(projectID: projectID),
      CreateConnectionTool(projectID: projectID),
      RequestReprocessTool(projectID: projectID),
    ]
  }
}

// MARK: - SynthesizeProject Tool

/// Saves the project synthesis with sections, metrics, and markdown content.
struct SynthesizeProjectTool: AgentTool {
  let name = "synthesize_project"
  let description = "Save the project synthesis with sections, metrics, and markdown content"
  let projectID: UUID

  var parameters: AIToolParameters {
    AIToolParameters(
      properties: [
        "markdown": AIToolProperty(
          type: "string", description: "Full synthesis in markdown format"),
        "sections": AIToolProperty(
          type: "array", description: "Array of {title, renderType, content} objects"),
        "metrics": AIToolProperty(
          type: "array", description: "Array of {label, value, format, status} objects"),
        "updatedFromItemIDs": AIToolProperty(
          type: "array", description: "UUID strings of items that contributed to this version"),
      ],
      required: ["markdown"]
    )
  }

  @MainActor
  func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult
  {
    guard let markdown = arguments["markdown"] as? String else {
      return ToolResult(
        content: "Error: markdown is required",
        citations: [],
        isError: true,
        displaySummary: "Missing markdown parameter"
      )
    }

    let sections: [SynthesisSection] =
      (arguments["sections"] as? [[String: Any]])?.compactMap { dict in
        guard let title = dict["title"] as? String,
          let renderType = dict["renderType"] as? String,
          let content = dict["content"] as? String
        else { return nil }
        return SynthesisSection(
          id: UUID().uuidString, title: title, renderType: renderType, content: content, order: 0)
      } ?? []

    let metrics: [SynthesisMetric] =
      (arguments["metrics"] as? [[String: Any]])?.compactMap { dict in
        guard let label = dict["label"] as? String,
          let value = dict["value"] as? Double
        else { return nil }
        return SynthesisMetric(
          id: UUID().uuidString,
          label: label,
          value: value,
          format: dict["format"] as? String ?? "number",
          status: dict["status"] as? String ?? "neutral",
          icon: dict["icon"] as? String
        )
      } ?? []

    let updatedFrom: [UUID] =
      (arguments["updatedFromItemIDs"] as? [String])?.compactMap(UUID.init(uuidString:)) ?? []

    let service = ProjectDerivedItemService(context: context.modelContext)
    do {
      _ = try service.createSynthesis(
        projectID: projectID,
        markdown: markdown,
        sections: sections,
        metrics: metrics,
        updatedFromItemIDs: updatedFrom
      )
      return ToolResult(
        content: "Synthesis saved (\(sections.count) sections, \(metrics.count) metrics)",
        citations: [],
        displaySummary: "Synthesis saved"
      )
    } catch {
      return ToolResult(
        content: "Error saving synthesis: \(error.localizedDescription)",
        citations: [],
        isError: true,
        displaySummary: "Save failed"
      )
    }
  }
}

// MARK: - EmitSignal Tool

/// Creates a signal (alert, risk, opportunity, doubt, pattern, contradiction) for the project.
struct EmitSignalTool: AgentTool {
  let name = "emit_signal"
  let description =
    "Create a signal (alert, risk, opportunity, doubt, pattern, contradiction) for the project"
  let projectID: UUID

  var parameters: AIToolParameters {
    AIToolParameters(
      properties: [
        "title": AIToolProperty(type: "string", description: "Signal title"),
        "signalType": AIToolProperty(
          type: "string", description: "risk, alert, opportunity, doubt, pattern, contradiction"),
        "description": AIToolProperty(type: "string", description: "Detailed description"),
        "suggestedAction": AIToolProperty(type: "string", description: "What the user should do"),
        "confidence": AIToolProperty(type: "number", description: "0.0-1.0 confidence"),
        "isCritical": AIToolProperty(type: "boolean", description: "Demands immediate attention"),
        "impactScore": AIToolProperty(type: "number", description: "0.0-1.0 impact"),
        "urgencyScore": AIToolProperty(type: "number", description: "0.0-1.0 urgency"),
        "relatedItemIDs": AIToolProperty(
          type: "array", description: "Related item UUIDs as strings"),
      ],
      required: ["title", "signalType", "description"]
    )
  }

  @MainActor
  func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult
  {
    guard let title = arguments["title"] as? String,
      let signalType = arguments["signalType"] as? String
    else {
      return ToolResult(
        content: "Error: title and signalType are required",
        citations: [],
        isError: true,
        displaySummary: "Missing required parameters"
      )
    }

    let body = SignalBody(
      signalType: signalType,
      description: arguments["description"] as? String ?? "",
      suggestedAction: arguments["suggestedAction"] as? String,
      relatedItemIDs: (arguments["relatedItemIDs"] as? [String])?.compactMap(
        UUID.init(uuidString:)),
      impactScore: arguments["impactScore"] as? Double,
      urgencyScore: arguments["urgencyScore"] as? Double
    )

    let service = ProjectDerivedItemService(context: context.modelContext)
    do {
      _ = try service.createSignal(
        title: title,
        projectID: projectID,
        signalBody: body,
        confidence: arguments["confidence"] as? Double,
        isCritical: arguments["isCritical"] as? Bool ?? false
      )
      return ToolResult(
        content: "Signal emitted: \(title)",
        citations: [],
        displaySummary: "Signal emitted"
      )
    } catch {
      return ToolResult(
        content: "Error emitting signal: \(error.localizedDescription)",
        citations: [],
        isError: true,
        displaySummary: "Signal failed"
      )
    }
  }
}

// MARK: - CreateConnection Tool

/// Creates a typed connection between two items or derivations.
struct CreateConnectionTool: AgentTool {
  let name = "create_connection"
  let description = "Create a typed connection between two items or derivations"
  let projectID: UUID

  var parameters: AIToolParameters {
    AIToolParameters(
      properties: [
        "fromID": AIToolProperty(type: "string", description: "Source item UUID"),
        "toID": AIToolProperty(type: "string", description: "Target item UUID"),
        "title": AIToolProperty(
          type: "string", description: "Human-readable connection description"),
        "edgeType": AIToolProperty(
          type: "string",
          description:
            "relatesTo, references, supports, contradicts, mentions, precedes, produced, belongsTo, assignedTo, blockedBy"
        ),
        "provenanceItemID": AIToolProperty(type: "string", description: "Evidence item UUID"),
      ],
      required: ["fromID", "toID", "title", "edgeType"]
    )
  }

  @MainActor
  func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult
  {
    guard let fromStr = arguments["fromID"] as? String,
      let fromID = UUID(uuidString: fromStr),
      let toStr = arguments["toID"] as? String,
      let toID = UUID(uuidString: toStr),
      let title = arguments["title"] as? String,
      let edgeTypeStr = arguments["edgeType"] as? String
    else {
      return ToolResult(
        content: "Error: fromID, toID, title, and edgeType are required and must be valid UUIDs",
        citations: [],
        isError: true,
        displaySummary: "Invalid parameters"
      )
    }

    let edgeType = EdgeType(rawValue: edgeTypeStr) ?? .references
    let provenance = (arguments["provenanceItemID"] as? String).flatMap(UUID.init(uuidString:))

    let service = ProjectDerivedItemService(context: context.modelContext)
    do {
      _ = try service.createConnection(
        title: title,
        projectID: projectID,
        fromDerivedID: fromID,
        toDerivedID: toID,
        edgeType: edgeType,
        provenanceItemID: provenance
      )
      return ToolResult(
        content: "Connection created: \(title)",
        citations: [],
        displaySummary: "Connection created"
      )
    } catch {
      return ToolResult(
        content: "Error creating connection: \(error.localizedDescription)",
        citations: [],
        isError: true,
        displaySummary: "Connection failed"
      )
    }
  }
}

// MARK: - RequestReprocess Tool

/// Marks items for re-analysis with project context.
struct RequestReprocessTool: AgentTool {
  let name = "request_reprocess"
  let description = "Mark items for re-analysis with project context"
  let projectID: UUID

  var parameters: AIToolParameters {
    AIToolParameters(
      properties: [
        "itemIDs": AIToolProperty(type: "array", description: "Item UUIDs to reprocess"),
        "context": AIToolProperty(
          type: "string", description: "Why reprocessing is needed, what to focus on"),
      ],
      required: ["itemIDs", "context"]
    )
  }

  @MainActor
  func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult
  {
    guard let itemIDStrs = arguments["itemIDs"] as? [String],
      let reprocessContext = arguments["context"] as? String
    else {
      return ToolResult(
        content: "Error: itemIDs and context are required",
        citations: [],
        isError: true,
        displaySummary: "Missing required parameters"
      )
    }

    let itemIDs = itemIDStrs.compactMap(UUID.init(uuidString:))
    let svc = ProjectService(context: context.modelContext)
    var successCount = 0
    var errorMessages: [String] = []

    for itemID in itemIDs {
      do {
        try svc.markForReprocessing(itemID: itemID, projectID: projectID, context: reprocessContext)
        successCount += 1
      } catch {
        errorMessages.append("Item \(itemID): \(error.localizedDescription)")
      }
    }

    var content = "\(successCount) items marked for reprocessing"
    if !errorMessages.isEmpty {
      content += "\nErrors: \(errorMessages.joined(separator: "; "))"
    }

    return ToolResult(
      content: content,
      citations: [],
      isError: !errorMessages.isEmpty,
      displaySummary: "\(successCount) items queued for reprocess"
    )
  }
}
