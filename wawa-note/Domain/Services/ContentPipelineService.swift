import Foundation
import SwiftData
import UIKit

/// Unified content pipeline: Extract text → Analyze → Project ingestion.
/// One job per item. Survives navigation and app backgrounding.
///
/// All content follows the same path — the source only determines how text is extracted:
/// - Audio  → transcribe → analyze
/// - Text   → analyze directly
/// - Image  → (future) LLM description → analyze
///
/// Phases that have already completed are skipped. Phase 3 (project ingestion)
/// always runs if the item has a projectID, regardless of earlier phase outcomes.
@MainActor
final class ContentPipelineService: ObservableObject {
    private let ingestionPipeline: ProjectIngestionPipeline
    private let ingestionState: ProjectIngestionState

    private var activeJobs: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskCount = 0

    init(ingestionPipeline: ProjectIngestionPipeline, ingestionState: ProjectIngestionState) {
        self.ingestionPipeline = ingestionPipeline
        self.ingestionState = ingestionState
    }

    /// Process an item through the pipeline: extract → analyze → ingest.
    /// Skips phases that already completed. Phase 3 always runs if projectID is set.
    func process(_ itemID: UUID, using modelContext: ModelContext) {
        guard activeJobs[itemID] == nil else {
            AppLog.provider.info("ContentPipeline: item \(itemID) already being processed, skipping duplicate call")
            return
        }

        let extraction = ContentExtractionService(modelContext: modelContext)

        activeJobs[itemID] = Task { @MainActor in
            defer {
                activeJobs[itemID] = nil
                endBackgroundTask()
                NotificationCenter.default.post(name: .pipelineCompleted, object: itemID.uuidString)
            }
            beginBackgroundTask()

            guard var item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) else {
                AppLog.provider.error("ContentPipeline: item \(itemID) not found in store, aborting")
                return
            }

            let isAudio = item.audioFileRelativePath != nil

            // ── Phase 1: Extract text ──────────────────────────
            let text: String?
            if isAudio && AutomationSettings.shared.autoTranscribe {
                text = await extraction.extractTextFromAudio(item)
                if let updated = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                    item = updated
                }
            } else if !isAudio {
                text = await extraction.extractTextFromDocument(item)
            } else {
                text = nil
            }

            // Best-effort fallback: use existing transcript/body/analysis so Phase 3
            // isn't blocked when re-extraction fails on an already-processed item.
            let effectiveText = text ?? extraction.bestAvailableText(for: item)

            guard let effectiveText, !effectiveText.isEmpty else {
                AppLog.provider.warning("ContentPipeline: no text available for item \(itemID) — skipping analysis and ingestion")
                return
            }

            // ── Phase 2: Analyze ──────────────────────────────
            if AutomationSettings.shared.autoAnalyze && item.analysisProviderId == nil {
                NotificationCenter.default.post(name: .contentPipelineStageChanged, object: itemID.uuidString,
                                                userInfo: ["stage": PipelineStage.analyzing.rawValue])

                // Resolve framework for analysis. Model is chosen internally by analyze/analyzeDynamic.
                if let projectID = item.projectID,
                   let project = try? ProjectService(context: modelContext).fetch(id: projectID) {
                    let framework = FrameworkService.shared.resolve(for: project)
                    if framework.id != "builtin/meeting" {
                        _ = await extraction.analyzeDynamic(text: effectiveText, item: item, framework: framework)
                    } else {
                        _ = await extraction.analyze(text: effectiveText, item: item)
                    }
                } else {
                    _ = await extraction.analyze(text: effectiveText, item: item)
                }
            } else if item.analysisProviderId != nil {
                AppLog.provider.info("ContentPipeline: item \(itemID) already analyzed (provider=\(item.analysisProviderId ?? "")), skipping Phase 2")
            }

            // ── Phase 3: Project ingestion ─────────────────────
            // Always fetch fresh — projectID may have been set after pipeline started.
            if let updated = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID),
               let projectID = updated.projectID {
                NotificationCenter.default.post(name: .contentPipelineStageChanged, object: itemID.uuidString,
                                                userInfo: ["stage": PipelineStage.ingesting.rawValue])
                await ingestionPipeline.ingest(itemID: itemID, projectID: projectID, using: modelContext)
            }
        }
    }

    /// Run only Phase 3 (project ingestion) for an item that has already been
    /// extracted and analyzed. Use this when assigning a fully-processed item
    /// to a project — avoids redundant re-transcription and re-analysis.
    func ingestOnly(_ itemID: UUID, projectID: UUID, using modelContext: ModelContext) {
        guard activeJobs[itemID] == nil else {
            AppLog.provider.info("ContentPipeline: item \(itemID) already processing, deferring ingestion to running job")
            return
        }

        activeJobs[itemID] = Task { @MainActor in
            defer {
                activeJobs[itemID] = nil
                endBackgroundTask()
                NotificationCenter.default.post(name: .pipelineCompleted, object: itemID.uuidString)
            }
            beginBackgroundTask()

            NotificationCenter.default.post(name: .contentPipelineStageChanged, object: itemID.uuidString,
                                            userInfo: ["stage": PipelineStage.ingesting.rawValue])
            await ingestionPipeline.ingest(itemID: itemID, projectID: projectID, using: modelContext)
        }
    }

    var isProcessing: Bool { !activeJobs.isEmpty }
    func isProcessingItem(_ itemID: UUID) -> Bool { activeJobs[itemID] != nil }

    private func beginBackgroundTask() {
        backgroundTaskCount += 1
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WawaPipeline") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        backgroundTaskCount -= 1
        guard backgroundTaskCount <= 0, backgroundTaskID != .invalid else { return }
        backgroundTaskCount = 0
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

// MARK: - Framework Service

/// Resolves which ProjectFramework to use for a project.
/// Falls back to builtin/meeting if no custom framework is set.
@MainActor
final class FrameworkService {
    static let shared = FrameworkService()

    private init() {}

    func resolve(for project: Project) -> ProjectFramework {
        if let json = project.frameworkJSON,
           let data = json.data(using: .utf8),
           let framework = try? JSONDecoder().decode(ProjectFramework.self, from: data) {
            return framework
        }
        return Self.meetingFramework
    }

    func validate(_ json: String) -> Result<ProjectFramework, Error> {
        guard let data = json.data(using: .utf8) else {
            return .failure(FrameworkError.invalidJSON)
        }
        do {
            let fw = try JSONDecoder().decode(ProjectFramework.self, from: data)
            return .success(fw)
        } catch {
            return .failure(error)
        }
    }

    func apply(to project: Project, framework: ProjectFramework) {
        project.frameworkId = framework.id
        if let data = try? JSONEncoder().encode(framework),
           let json = String(data: data, encoding: .utf8) {
            project.frameworkJSON = json
        }
    }

    // MARK: Built-in frameworks

    static var meetingFramework: ProjectFramework {
        let schema = AnalysisOutputSchema(type: "object", properties: [
            "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
            "detailed_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "Detailed summary"),
            "decisions": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                "title": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                "details": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
            ]), properties: nil, description: "Decisions made"),
            "action_items": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                "task": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                "owner": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                "due_date": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
            ]), properties: nil, description: "Action items"),
            "risks": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                "risk": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                "details": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
            ]), properties: nil, description: "Risks identified"),
            "open_questions": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                "question": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
            ]), properties: nil, description: "Open questions"),
            "important_dates": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                "date": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                "meaning": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
            ]), properties: nil, description: "Important dates"),
            "entities": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                "name": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                "type": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
            ]), properties: nil, description: "Entities mentioned")
        ], required: ["short_summary"])

        return ProjectFramework(
            id: "builtin/meeting",
            name: "Meeting Analysis",
            description: "Extracts decisions, action items, risks, open questions, dates, and entities from meeting content.",
            itemAnalysis: AnalysisConfig(
                systemPrompt: "You are a meeting intelligence analyst. Extract decisions, action items with owners, risks, open questions, important dates, and mentioned people/systems/organizations. Return only valid JSON.",
                outputSchema: schema,
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "decisions", type: .list, title: "Decisions", icon: "checkmark.shield"),
                    FieldRenderer(field: "action_items", type: .list, title: "Action Items", icon: "checklist"),
                    FieldRenderer(field: "risks", type: .list, title: "Risks", icon: "exclamationmark.triangle"),
                    FieldRenderer(field: "open_questions", type: .list, title: "Open Questions", icon: "questionmark.circle"),
                    FieldRenderer(field: "entities", type: .chips, title: "Mentioned", icon: "tag")
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "You are a project knowledge analyst. Analyze how this item relates to the project.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)
            ),
            views: [
                ViewDefinition(id: "tasks", title: "Tasks", type: .kanban, source: "tasks"),
                ViewDefinition(id: "items", title: "Items", type: .list, source: "items"),
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges"),
                ViewDefinition(id: "timeline", title: "Timeline", type: .timeline, source: "items")
            ],
            entityKinds: ["person", "organization", "system", "repository", "location"],
            edgeTypes: ["supports", "contradicts", "references", "relates_to", "precedes", "mentions", "assigned_to"]
        )
    }

    static var researchFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/research",
            name: "Research",
            description: "Tracks hypotheses, findings, sources, and methods across research items.",
            itemAnalysis: AnalysisConfig(
                systemPrompt: "You are a research analyst. Extract hypotheses, findings, sources cited, methodology notes, open questions, and key themes from this content. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [
                    "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                    "hypotheses": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                        "statement": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        "confidence": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
                    ]), properties: nil, description: "Hypotheses proposed or tested"),
                    "findings": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                        "description": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        "source": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
                    ]), properties: nil, description: "Key findings"),
                    "themes": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Key themes")
                ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "hypotheses", type: .list, title: "Hypotheses", icon: "lightbulb"),
                    FieldRenderer(field: "findings", type: .list, title: "Findings", icon: "magnifyingglass"),
                    FieldRenderer(field: "themes", type: .chips, title: "Themes", icon: "tag")
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "You synthesize research projects. Identify emerging patterns, confirmed/refuted hypotheses, and gaps.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)
            ),
            views: [
                ViewDefinition(id: "items", title: "Items", type: .list, source: "items"),
                ViewDefinition(id: "hypotheses", title: "Hypotheses", type: .cards, source: "analysis.hypotheses"),
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges"),
                ViewDefinition(id: "timeline", title: "Timeline", type: .timeline, source: "items")
            ],
            entityKinds: ["hypothesis", "finding", "source", "method", "theme"],
            edgeTypes: ["supports", "contradicts", "cites", "builds_on", "refutes"]
        )
    }

    static var brainstormFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/brainstorm",
            name: "Brainstorm",
            description: "Captures ideas, clusters themes, and surfaces questions from brainstorming sessions.",
            itemAnalysis: AnalysisConfig(
                systemPrompt: "You analyze brainstorming content. Extract ideas, themes, questions raised, and connections between concepts. Do NOT extract decisions or action items. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [
                    "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                    "ideas": SchemaProperty(type: "array", items: SchemaItems(type: "object", properties: [
                        "idea": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        "category": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
                    ]), properties: nil, description: "Ideas generated"),
                    "themes": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Emerging themes"),
                    "questions": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Questions raised")
                ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "ideas", type: .list, title: "Ideas", icon: "lightbulb"),
                    FieldRenderer(field: "themes", type: .chips, title: "Themes", icon: "tag"),
                    FieldRenderer(field: "questions", type: .list, title: "Questions", icon: "questionmark.circle")
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "You synthesize brainstorming projects. Identify dominant themes, idea clusters, and unexplored areas.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)
            ),
            views: [
                ViewDefinition(id: "ideas", title: "Ideas", type: .cards, source: "analysis.ideas"),
                ViewDefinition(id: "items", title: "Items", type: .list, source: "items"),
                ViewDefinition(id: "themes", title: "Themes", type: .chips, source: "analysis.themes"),
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges")
            ],
            entityKinds: ["idea", "theme", "question", "category"],
            edgeTypes: ["clusters_with", "inspires", "extends", "contradicts"]
        )
    }

    static var journalFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/journal",
            name: "Journal",
            description: "Personal journal with theme tracking, mood patterns, and cross-reference discovery.",
            itemAnalysis: AnalysisConfig(
                systemPrompt: "You analyze personal journal entries. Extract themes, mood if evident, people mentioned, places, and cross-references to past entries. Do NOT extract decisions or risks. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [
                    "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                    "themes": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Themes"),
                    "people_mentioned": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "People mentioned"),
                    "places": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Places mentioned")
                ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "themes", type: .chips, title: "Themes", icon: "tag"),
                    FieldRenderer(field: "people_mentioned", type: .chips, title: "People", icon: "person"),
                    FieldRenderer(field: "places", type: .chips, title: "Places", icon: "mappin")
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "You synthesize personal journals. Identify recurring themes, mood patterns, and evolving perspectives.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)
            ),
            views: [
                ViewDefinition(id: "entries", title: "Entries", type: .list, source: "items"),
                ViewDefinition(id: "themes", title: "Themes", type: .cards, source: "analysis.themes"),
                ViewDefinition(id: "timeline", title: "Timeline", type: .timeline, source: "items"),
                ViewDefinition(id: "graph", title: "Connections", type: .graph, source: "edges")
            ],
            entityKinds: ["theme", "person", "place", "event"],
            edgeTypes: ["relates_to", "follows_up", "references", "contradicts"]
        )
    }

    static var blankFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/blank",
            name: "Blank",
            description: "Minimal schema. The AI will adapt analysis to whatever content you add.",
            itemAnalysis: AnalysisConfig(
                systemPrompt: "Analyze this content and extract whatever is most relevant. Return a JSON object with fields that make sense for this specific content. Include at least a 'short_summary' string field.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [
                    "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary")
                ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft")
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "Synthesize this project's items. Identify whatever patterns, themes, or insights are most relevant.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)
            ),
            views: [
                ViewDefinition(id: "items", title: "Items", type: .list, source: "items"),
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges")
            ],
            entityKinds: [],
            edgeTypes: ["relates_to", "references"]
        )
    }
}

enum FrameworkError: Error, LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "The framework JSON is not valid."
        }
    }
}

// MARK: - Pipeline stage (for UI progress)

enum PipelineStage: String, Sendable {
    case extracting = "Extracting content..."
    case analyzing = "Analyzing..."
    case ingesting = "Updating project..."
}

