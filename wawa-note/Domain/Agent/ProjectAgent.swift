import Foundation
import SwiftData
import WawaNoteCore

/// ProjectAgent — runs AgentLoop scoped to a project's items.
/// Generates synthesis, emits signals, creates connections.
/// Does NOT reprocess individual items — delegates that to Item Agent.
@MainActor
final class ProjectAgent {
  private let projectID: UUID
  private let context: ModelContext
  private let projectService: ProjectService
  private let derivedService: ProjectDerivedItemService

  init(projectID: UUID, context: ModelContext) {
    self.projectID = projectID
    self.context = context
    self.projectService = ProjectService(context: context)
    self.derivedService = ProjectDerivedItemService(context: context)
  }

  // MARK: - Synthesis generation

  /// Generates or updates the project synthesis by running the agent over
  /// all item derivations and project context.
  func generateSynthesis() async throws -> ProjectDerivedItem {
    guard let project = try projectService.fetch(id: projectID) else {
      throw ProjectAgentError.projectNotFound
    }

    // 1. Gather context: item derivations + existing synthesis
    let items = (try? projectService.items(in: projectID)) ?? []
    let existingSynthesis = try? derivedService.fetchSynthesis(for: projectID).first
    let existingTasks = (try? derivedService.fetch(for: projectID, type: .task)) ?? []
    let existingSignals = (try? derivedService.fetch(for: projectID, type: .signal)) ?? []
    let edges =
      (try? GraphEdgeService(context: context).neighborhood(of: projectID, radius: 2)) ?? []

    // 2. Detect domain framework
    let domainFramework = await detectDomain()
    if let fw = domainFramework {
      AppLog.general.info(
        "ProjectAgent: detected domain framework '\(fw.name)' for project '\(project.name)'")
    }

    // 3. Build context description (with framework context if detected)
    let contextDescription = buildContextDescription(
      project: project,
      items: items,
      existingSynthesis: existingSynthesis,
      tasks: existingTasks,
      signals: existingSignals,
      edges: edges,
      domainFramework: domainFramework
    )

    // 4. Set up tools and context
    let tools = ProjectTools.makeTools(projectID: projectID)
    let toolContext = ToolContext(
      modelContext: context,
      fileStore: FileArtifactStore(),
      activeProjectID: projectID,
      activeProjectName: project.name,
      activeProjectSlug: project.slug,
      contextKey: "project:\(projectID.uuidString)",
      contextDisplayName: project.name
    )

    let loop = AgentLoop(
      registry: AgentToolRegistry(tools: tools),
      toolContext: toolContext,
      mode: .deep,
      executorModel: AIConfigService.shared.modelFor(feature: "analysis"),
      advisorModel: AIConfigService.shared.modelFor(feature: "analysis")
    )

    // 4. Resolve AI provider
    let provider: any AIProvider
    do {
      provider = try ProviderRouter.resolveActive(context: context)
    } catch {
      throw ProjectAgentError.providerNotConfigured
    }

    // 5. Run agent autonomously
    var taskPrompt = """
      You are the Project Agent for "\(project.name)".
      Your universe is this project's items and their derivations.

      ## PROJECT CONTEXT
      \(contextDescription)

      ## YOUR TASK
      Generate a project synthesis that:

      1. Summarizes the current state of the project (2-3 paragraphs)
      2. Lists active decisions and their status
      3. Identifies risks and their mitigation status
      4. Highlights cross-item connections and patterns
      5. Provides metrics: decision velocity, task completion rate, risk exposure

      Use the `synthesize_project` tool to save your output.
      If you detect contradictions across items, create signals using `emit_signal`.
      If you find items that need re-analysis with project context, use `request_reprocess`.
      Use `create_connection` to link related items.
      """

    // Append framework-specific synthesis instructions if available
    if let fw = domainFramework {
      taskPrompt += """

        ## DOMAIN FRAMEWORK: \(fw.name)

        This project has been classified under the "\(fw.name)" domain framework.

        Framework synthesis instructions:
        \(fw.projectSynthesis.systemPrompt)
        """
    }

    let fullOutput = try await runAutonomousLoop(
      loop: loop,
      task: taskPrompt,
      systemPrompt:
        "You are a project synthesis agent. Analyze the project context and use the available tools to produce a comprehensive synthesis.",
      tools: tools,
      provider: provider,
      maxIterations: 12
    )

    // 6. Parse result and create/update synthesis
    let synthesis = try parseAndSaveSynthesis(result: fullOutput, projectID: projectID)
    return synthesis
  }

  // MARK: - Domain detection

  /// Detects the most appropriate framework/domain for this project
  /// based on the content of its items. Uses keyword scoring against
  /// built-in framework definitions.
  func detectDomain() async -> ProjectFramework? {
    let items = (try? projectService.items(in: projectID)) ?? []
    guard !items.isEmpty else { return nil }

    // Build a sample of item content (titles + types + any analysis summaries)
    var sampleText = ""
    let store = FileArtifactStore()
    for item in items.prefix(5) {
      sampleText += "\(item.type.label): \(item.title)\n"
      let analysisURL = store.meetingDirectoryURL(for: item.id)
        .appendingPathComponent("analysis.json")
      if let data = try? Data(contentsOf: analysisURL),
        let text = String(data: data, encoding: .utf8)
      {
        sampleText += String(text.prefix(200)) + "\n"
      }
    }

    // Match against built-in frameworks
    let frameworks = FrameworkService.allBuiltInFrameworks
    guard !frameworks.isEmpty, !sampleText.isEmpty else { return nil }

    // Simple keyword scoring — in production, use the AI to classify
    var scores: [(framework: ProjectFramework, score: Int)] = []
    for (_, framework) in frameworks {
      var score = 0
      let keywords = extractFrameworkKeywords(framework)
      for keyword in keywords {
        if sampleText.localizedCaseInsensitiveContains(keyword) {
          score += 1
        }
      }
      if score > 0 {
        scores.append((framework, score))
      }
    }

    scores.sort { $0.score > $1.score }
    return scores.first?.framework
  }

  private func extractFrameworkKeywords(_ framework: ProjectFramework) -> [String] {
    var keywords: [String] = []
    keywords.append(contentsOf: framework.name.components(separatedBy: " "))
    keywords.append(contentsOf: framework.entityKinds)
    keywords.append(contentsOf: framework.edgeTypes)
    return keywords.map { $0.lowercased() }
  }

  // MARK: - Device context enrichment

  /// Enriches newly added items with device context (Calendar, Contacts, Location).
  func enrichWithDeviceContext(itemIDs: [UUID]) async throws {
    let deviceContext = DeviceContextService()
    for itemID in itemIDs {
      guard let item = try fetchKnowledgeItem(itemID) else { continue }
      let enrichments = await deviceContext.crossReference(item: item)
      for enrichment in enrichments {
        switch enrichment {
        case .calendarEvent(let event):
          _ = try derivedService.createConnection(
            title: "\(item.title) → Calendar: \(event.title)",
            projectID: projectID,
            fromDerivedID: item.id,
            toDerivedID: projectID,
            edgeType: .references,
            provenanceItemID: item.id
          )
        case .contact(let person):
          let personID = try ensurePersonExists(person, context: context)
          try GraphEdgeService(context: context).create(
            fromID: item.id,
            toID: personID,
            edgeType: .mentions,
            provenanceItemID: item.id
          )
        case .location(let place):
          AppLog.general.info(
            "DeviceContext: item \(item.title.prefix(20)) matched location \(place)")
        }
      }
    }
    AppLog.general.info(
      "ProjectAgent: enrichWithDeviceContext complete — \(itemIDs.count) items processed")
  }

  // MARK: - Reprocess triggers

  /// Detects items that need re-analysis with project context and emits triggers.
  func detectReprocessNeeds() async throws -> [UUID] {
    let items = (try? projectService.items(in: projectID)) ?? []
    let candidates = items.filter { $0.needsProjectReprocessing }
    for item in candidates {
      let context =
        item.projectReprocessContext
        ?? "Project: \(try? projectService.fetch(id: projectID)?.name ?? "")"
      AppLog.general.info(
        "ProjectAgent: item \(item.title.prefix(20)) needs reprocessing with context: \(context)")
    }
    return candidates.map(\.id)
  }

  // MARK: - Private

  /// Runs the AgentLoop autonomously and collects the full text output.
  private func runAutonomousLoop(
    loop: AgentLoop,
    task: String,
    systemPrompt: String,
    tools: [any AgentTool],
    provider: any AIProvider,
    maxIterations: Int?
  ) async throws -> String {
    var fullOutput = ""
    let stream = loop.runAutonomous(
      task: task,
      systemPrompt: systemPrompt,
      tools: tools,
      provider: provider,
      maxIterations: maxIterations,
      timeoutSeconds: 300
    )
    for try await event in stream {
      switch event {
      case .textDelta(let d):
        fullOutput += d
      case .error(let error):
        AppLog.agent.error("ProjectAgent loop error: \(error.localizedDescription)")
      case .truncated(let reason, let progress):
        AppLog.agent.warning("ProjectAgent loop truncated: \(reason) (\(progress))")
      // Continue collecting partial output rather than throwing
      case .finished:
        break
      default:
        break
      }
    }
    return fullOutput
  }

  private func buildContextDescription(
    project: Project,
    items: [KnowledgeItem],
    existingSynthesis: ProjectDerivedItem?,
    tasks: [ProjectDerivedItem],
    signals: [ProjectDerivedItem],
    edges: [GraphEdge],
    domainFramework: ProjectFramework? = nil
  ) -> String {
    var desc = "PROJECT: \(project.name)\n"
    if let intent = project.intention { desc += "Intention: \(intent)\n" }
    if let summary = project.summary { desc += "Summary: \(summary)\n" }

    if let fw = domainFramework {
      desc += "DOMAIN FRAMEWORK: \(fw.name)\n"
      desc += "Framework description: \(fw.description)\n"
      desc += "Entity kinds: \(fw.entityKinds.joined(separator: ", "))\n"
      desc += "Edge types: \(fw.edgeTypes.joined(separator: ", "))\n"
    }

    desc += "\nITEMS (\(items.count)):\n"
    for item in items.prefix(20) {
      desc +=
        "- [\(item.type.label)] \(item.title) (\(item.createdAt.formatted(date: .abbreviated, time: .omitted)))\n"
    }

    desc += "\nTASKS (\(tasks.count)):\n"
    for task in tasks.prefix(15) {
      desc += "- [\(task.statusRaw ?? "?")] \(task.title)"
      if let owner = task.ownerName { desc += " \u{00B7} \(owner)" }
      if let due = task.dueAt {
        desc += " \u{00B7} due \(due.formatted(date: .abbreviated, time: .omitted))"
      }
      desc += "\n"
    }

    desc += "\nSIGNALS (\(signals.count)):\n"
    for signal in signals.prefix(10) {
      desc += "- [\(signal.statusRaw ?? "?")] \(signal.title)"
      if signal.isCritical { desc += " [CRITICAL]" }
      desc += "\n"
    }

    if let existing = existingSynthesis, let bodyJSON = existing.bodyJSON {
      desc += "\nEXISTING SYNTHESIS (abbreviated):\n"
      desc += String(bodyJSON.prefix(500)) + "...\n"
    }

    return desc
  }

  private func fetchKnowledgeItem(_ id: UUID) throws -> KnowledgeItem? {
    var descriptor = FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func parseAndSaveSynthesis(result: String, projectID: UUID) throws -> ProjectDerivedItem {
    let sections = extractSynthesisSections(from: result)
    let metrics = extractMetrics(from: result)

    return try derivedService.createSynthesis(
      projectID: projectID,
      markdown: result,
      sections: sections,
      metrics: metrics,
      updatedFromItemIDs: []
    )
  }

  private func extractSynthesisSections(from text: String) -> [SynthesisSection] {
    var sections: [SynthesisSection] = []
    var order = 0
    let lines = text.components(separatedBy: "\n")
    var currentTitle = ""
    var currentContent = ""
    for line in lines {
      if line.hasPrefix("## ") {
        if !currentTitle.isEmpty {
          sections.append(
            SynthesisSection(
              id: UUID().uuidString,
              title: currentTitle,
              renderType: "markdown",
              content: currentContent,
              order: order
            ))
          order += 1
        }
        currentTitle = String(line.dropFirst(3))
        currentContent = ""
      } else {
        currentContent += line + "\n"
      }
    }
    if !currentTitle.isEmpty {
      sections.append(
        SynthesisSection(
          id: UUID().uuidString,
          title: currentTitle,
          renderType: "markdown",
          content: currentContent,
          order: order
        ))
    }
    return sections
  }

  private func extractMetrics(from text: String) -> [SynthesisMetric] {
    // Computed defaults — enhanced when agent emits structured metrics via tool calls.
    let derivedSvc = ProjectDerivedItemService(context: context)
    let activeTasks = (try? derivedSvc.fetchActiveTasks(for: projectID)) ?? []
    let activeSignals = (try? derivedSvc.fetchActiveSignals(for: projectID)) ?? []
    let items = (try? projectService.items(in: projectID)) ?? []

    return [
      SynthesisMetric(
        id: "item_count", label: "Items", value: Double(items.count),
        format: "number", status: items.isEmpty ? "warning" : "healthy", icon: "doc.fill"
      ),
      SynthesisMetric(
        id: "active_tasks", label: "Active Tasks", value: Double(activeTasks.count),
        format: "number", status: activeTasks.count > 10 ? "warning" : "healthy", icon: "checklist"
      ),
      SynthesisMetric(
        id: "active_signals", label: "Active Signals", value: Double(activeSignals.count),
        format: "number",
        status: activeSignals.contains { $0.isCritical }
          ? "critical" : (activeSignals.count > 5 ? "warning" : "healthy"),
        icon: "waveform.path.ecg"
      ),
    ]
  }
}

// MARK: - Errors

enum ProjectAgentError: Error {
  case projectNotFound
  case providerNotConfigured
  case synthesisFailed(String)
}

extension ProjectAgentError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .projectNotFound:
      return "Project not found"
    case .providerNotConfigured:
      return "No AI provider is configured. Please configure a provider in Settings."
    case .synthesisFailed(let reason):
      return "Synthesis failed: \(reason)"
    }
  }
}
