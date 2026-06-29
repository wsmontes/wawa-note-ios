import Foundation
import JavaScriptCore
import Network
import PDFKit
import SwiftData
import UIKit

// MARK: - Pipeline Agent Templates

/// Pipeline agent templates define the behavior, rules, and strategy
/// for autonomous content processing agents.
///
/// In Phase 2, these become editable PromptTemplate records in SwiftData.
enum PipelineTemplate {

    /// The standard content processing pipeline: Extract → Analyze → Ingest.
    /// Uses the virtual filesystem shell (run_command) for all operations.
    static let standard: String = """
        You are a content analysis agent in Wawa Note. Process the item described in the first message.

        ## TOOLS

        You have three tools:
        - run_command: shell commands for exploration (extract, ls, cat, grep, echo)
        - set_title: rename the item after reading content (call BEFORE analysis)
        - write_analysis: save your structured analysis

        ## MANDATORY STEPS

        ### Step 1: EXTRACT (always first)
        Use run_command: `extract <item-id>`
        If empty or fails, report and stop.

        ### Step 2: TITLE (after reading)
        Read the extracted content. Generate a concise, descriptive title
        (5-10 words) that captures the essence. Call set_title with the title.
        Better than generic names like "Recording 2026-06-15".

        ### Step 3: ANALYZE (adaptive)
        Review the content and decide which sections are relevant. Not all content needs the same sections — a casual note and a formal meeting have different needs.

        Produce a JSON object with sections YOU choose. Use write_analysis:
        - itemId: the item's UUID
        - analysisJson: a JSON object where each key is a section name and each value is the section content

        ## SECTION GUIDELINES

        Choose sections that MATCH the content. Common examples:
        - "summary": always include — one paragraph capturing the essence
        - "key_points": main takeaways as a list of strings
        - "decisions": [{"decision": "...", "context": "..."}] — only if decisions were made
        - "action_items": [{"task": "...", "owner": "...", "deadline": "..."}] — only if tasks assigned
        - "risks": [{"risk": "...", "mitigation": "..."}] — only if risks discussed
        - "open_questions": ["..."] — only if questions raised
        - "people_mentioned": ["name"] — only if people named
        - "topics_discussed": ["topic"] — list of subjects
        - "sentiment": "positive/neutral/negative" — overall tone
        - "custom_sections": {} — any other relevant groupings you identify

        ### Step 4: SPEAKER RESOLUTION (when transcript has speakers)
        After write_analysis, identify speakers mentioned in the transcript.
        Use `person "Name"` to cross-reference each speaker across contacts,
        calendar, transcripts, and memory. Compare results carefully — homonyms
        are common, disambiguate by context (company, recent meetings, other speakers).
        When uncertain, add to pending_confirmations with evidence for each candidate.
        Output via write_speakers — the schema is strictly validated. Retry until it passes.

        ## RULES
        - ALWAYS start with extract
        - ALWAYS use write_analysis — never just describe results
        - "summary" is the only REQUIRED section. All others are OPTIONAL.
        - ONLY include sections that have meaningful content. Skip empty ones entirely (don't use null).
        - If content quality is too low to analyze (blurry scan, inaudible audio, garbled OCR), produce a minimal analysis with "summary" explaining why and stop. Do NOT loop retrying on unanalyzable content.
        - You may add custom sections beyond the examples above if the content warrants it.
        - Be specific — reference what was actually said
        - Use snake_case for section keys
        """

    /// Build a framework-aware prompt that includes the project's schema sections.
    static func forFramework(_ framework: ProjectFramework) -> String {
        let props = framework.itemAnalysis.outputSchema.properties
        let sectionList = props.keys.sorted().map { "  - \"\($0)\"" }.joined(separator: "\n")
        let desc = framework.description

        return """
            You are a content analysis agent in Wawa Note. Process the item described in the first message.

            ## FRAMEWORK: \(framework.name)
            \(desc)

            ## TOOLS
            - run_command: extract, ls, cat, grep, echo
            - write_analysis: save your structured analysis

            ## STEPS
            1. EXTRACT: use `extract <item-id>`
            2. ANALYZE: decide which sections apply, produce JSON, call write_analysis

            ## AVAILABLE SECTIONS (choose which apply):
            \(sectionList)

            ## RULES
            - ALWAYS start with extract
            - Include a "summary" section with a one-paragraph synthesis
            - ONLY include sections that have meaningful content from the source
            - Skip sections where nothing relevant was found — omit them entirely
            - You may add up to 3 custom sections beyond the available list if the content warrants it
            - Be specific and reference what was actually said
            - Use the exact section key names from the available list
            """
    }

    /// Lightweight pipeline: extract and analyze only. No project ingestion.
    static let extractAndAnalyze: String = """
        You are a content processing agent. Extract text from the given item and analyze it. \
        Do NOT perform project ingestion (no tasks, edges, or annotations). \
        Output only the analysis summary. Follow the same cost and error rules as the standard pipeline.
        """
}

// MARK: - Content Pipeline Service

/// Unified content pipeline using an autonomous agent loop.
/// Replaces the rigid extract→analyze→ingest flow with agent-driven processing.
/// The agent decides strategy based on content size, type, and complexity.
@MainActor
final class ContentPipelineService: ObservableObject {
    private let ingestionPipeline: ProjectIngestionPipeline
    private let ingestionState: ProjectIngestionState
    private let modelContainer: ModelContainer

    @Published var pipelineStatus: PipelineProgress?

    private var activeJobs: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskCount = 0

    init(ingestionPipeline: ProjectIngestionPipeline, ingestionState: ProjectIngestionState, modelContainer: ModelContainer) {
        self.ingestionPipeline = ingestionPipeline
        self.ingestionState = ingestionState
        self.modelContainer = modelContainer
    }

    /// Builds the catalog prompt that teaches the agent how to choose schema + skill
    /// based on content. Lists available schemas and skills compactly.
    static func buildCatalogPrompt() -> String {
        let schemaList = AnalysisSchemaStore.shared.schemas.values
            .sorted { $0.displayName < $1.displayName }
            .map { "\($0.name) — \($0.displayName): \($0.description)" }
            .joined(separator: "\n")
        let skillList = AnalysisSkillStore.shared.skills.values
            .sorted { $0.displayName < $1.displayName }
            .map { "\($0.name) — \($0.displayName): \($0.description)" }
            .joined(separator: "\n")
        return """
            ## ANALYSIS SETUP

            Read the content, then decide your approach:

            1. If a schema below clearly matches the content, call `select_schema <name>`:
            \(schemaList)

            2. If a skill below provides useful guidance, call `select_skill <name>`:
            \(skillList)

            If nothing fits well, skip both and proceed directly to write_analysis.
            You can define your own structure based on what the content actually needs.
            The UI will adapt to whatever fields you produce.
            """
    }

    /// Process an item through the pipeline using an autonomous agent.
    /// The agent decides the strategy (single-pass, chunked, map-reduce) based on
    /// content size and type. Skips phases that already completed.
    func process(_ itemID: UUID, using modelContext: ModelContext, forceReanalysis: Bool = false, extractionOnly: Bool = false) {
        guard activeJobs[itemID] == nil else {
            AppLog.provider.info("ContentPipeline: item \(itemID) already being processed, skipping duplicate call")
            return
        }

        activeJobs[itemID] = Task { @MainActor in
            defer {
                activeJobs[itemID] = nil
                endBackgroundTask()
                NotificationCenter.default.post(name: .pipelineCompleted, object: itemID.uuidString)
            }
            guard !Task.isCancelled else { return }
            beginBackgroundTask()

            guard let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) else {
                AppLog.provider.error("ContentPipeline: item \(itemID) not found in store, aborting")
                return
            }

            // Respect the extraction review gate. Items in pendingReview wait for
            // the user to approve the extracted text before analysis proceeds.
            // When forceReanalysis is true, skip — caller explicitly requested a run.
            guard forceReanalysis || item.status != .pendingReview else {
                AppLog.provider.info("ContentPipeline: item \(itemID) pending review — waiting for user approval")
                return
            }

            // Skip if already analyzed (re-analyze is triggered manually via the UI).
            // When forceReanalysis is true, bypass this guard — caller has already
            // cleared analysisProviderId and wants a fresh analysis run.
            guard forceReanalysis || item.analysisProviderId == nil || !AutomationSettings.shared.autoAnalyze else {
                AppLog.provider.info("ContentPipeline: item \(itemID) already analyzed, skipping")
                // Still run ingestion if needed
                if let projectID = item.projectID {
                    await ingestionPipeline.ingest(itemID: itemID, projectID: projectID, using: modelContext)
                }
                return
            }

            let fileStore = FileArtifactStore()

            // Phase 0: Pre-extraction — transcribe audio, OCR images, fetch bookmarks.
            // These operations don't require an AI provider and run before analysis.
            let extractionSvc = ContentExtractionService(modelContext: modelContext, fileStore: fileStore)

            if AutomationSettings.shared.autoTranscribe {
                if item.type == .audio, extractionSvc.needsTranscription(for: item) {
                    pipelineStatus = PipelineProgress(
                        itemId: itemID, itemTitle: item.title,
                        itemType: item.type.rawValue, phase: "transcribing",
                        currentTool: nil, toolSummary: nil, toolLog: [], events: [], thinkingActive: false)
                    // Update item status so KnowledgeDetailView can show the right indicator
                    // without guessing. This is the authoritative state transition.
                    item.status = .transcribing
                    do { try modelContext.save() } catch {
                        AppLog.provider.error("ContentPipeline: save failed (→transcribing): \(error.localizedDescription)")
                    }
                    NotificationCenter.default.post(
                        name: .contentPipelineStageChanged, object: itemID.uuidString,
                        userInfo: ["stage": "transcribing"])
                    if let transcribedText = await extractionSvc.extractTextFromAudio(item) {
                        AppLog.provider.info("ContentPipeline: pre-transcription complete for item \(itemID) — \(transcribedText.count) chars")
                        // Set pendingReview so user can verify transcription before analysis
                        if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                            fresh.status = .pendingReview
                            do { try modelContext.save() } catch {
                                AppLog.provider.error("ContentPipeline: save failed (transcribe→pendingReview): \(error.localizedDescription)")
                            }
                        }
                    } else {
                        AppLog.provider.warning("ContentPipeline: pre-transcription failed for item \(itemID) — marking as failed")
                        if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                            fresh.status = .failed
                            try? modelContext.save()
                        }
                    }
                }
                if item.type == .image, item.bodyText == nil {
                    let pageCount = item.imagePageCount ?? 1
                    item.status = .transcribing
                    try? modelContext.save()
                    pipelineStatus = PipelineProgress(
                        itemId: itemID, itemTitle: item.title,
                        itemType: item.type.rawValue, phase: "recognizing",
                        currentTool: nil, toolSummary: nil, toolLog: [], events: [], thinkingActive: false)
                    NotificationCenter.default.post(
                        name: .contentPipelineStageChanged, object: itemID.uuidString,
                        userInfo: ["stage": "Extracting text" + (pageCount > 1 ? " (\(pageCount) pages)" : "")])
                    if let ocrText = await extractionSvc.extractTextFromImage(item) {
                        let hasVision = ocrText.contains("VISUAL ANALYSIS")
                        AppLog.provider.info("ContentPipeline: extraction complete for item \(itemID) — \(ocrText.count) chars, vision=\(hasVision)")
                        NotificationCenter.default.post(
                            name: .contentPipelineStageChanged, object: itemID.uuidString,
                            userInfo: ["stage": "OCR done (\(ocrText.count) chars" + (hasVision ? " + vision)" : ")")])
                        // Set pendingReview so user can verify extraction before analysis
                        if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                            fresh.status = .pendingReview
                            do { try modelContext.save() } catch {
                                AppLog.provider.error("ContentPipeline: save failed (OCR→pendingReview): \(error.localizedDescription)")
                            }
                        }
                    } else {
                        AppLog.provider.warning("ContentPipeline: OCR failed for item \(itemID)")
                    }
                }
                if item.type == .webBookmark, item.bodyText == nil {
                    pipelineStatus = PipelineProgress(
                        itemId: itemID, itemTitle: item.title,
                        itemType: item.type.rawValue, phase: "fetching",
                        currentTool: nil, toolSummary: nil, toolLog: [], events: [], thinkingActive: false)
                    // bestAvailableText handles the fetch; call it to cache the result
                    _ = await extractionSvc.bestAvailableText(for: item)
                }
            }

            // Extraction-only mode: stop after Phase 0, don't run analysis.
            if extractionOnly {
                AppLog.provider.info("ContentPipeline: extractionOnly — stopping after Phase 0 for \(itemID)")
                return
            }

            guard let provider = try? ProviderRouter.resolveActive(context: modelContext) else {
                AppLog.provider.error("ContentPipeline: no active provider configured — transcription-only mode")
                if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                    fresh.status = fresh.transcriptionEngineId != nil ? .transcribed : .recorded
                    do { try modelContext.save() } catch {
                        AppLog.provider.error("ContentPipeline: critical save failed (transcription-only): \(error.localizedDescription)")
                    }
                }
                return
            }
            let project = item.projectID.flatMap { pid in try? ProjectService(context: modelContext).fetch(id: pid) }
            let resolvedFramework = project.flatMap { FrameworkService.shared.resolve(for: $0) }
            let toolContext = ToolContext(
                modelContext: modelContext, fileStore: fileStore,
                activeProjectID: item.projectID,
                activeProjectName: project?.name,
                activeProjectSlug: project?.slug,
                sandboxedItemID: itemID,  // Agent restricted to this item's folder
                activeFramework: resolvedFramework  // Schema for write_analysis validation
            )

            let tools: [any AgentTool] = [
                ShellTool(),
                SetTitleTool(),
                SelectSchemaTool(),
                SelectSkillTool(),
                WriteAnalysisTool(),
                WriteSpeakersTool(),
            ]

            let catalogPrompt = Self.buildCatalogPrompt()
            let systemPrompt = catalogPrompt + "\n\n" + (resolvedFramework.map { PipelineTemplate.forFramework($0) } ?? PipelineTemplate.standard)
            let pipelineDef = PipelineStore.shared.active
            let iterationBudget = pipelineDef?.params?.maxIterations ?? 15
            let agentMode: AgentMode = pipelineDef?.params?.agentMode == "deep" ? .deep : (pipelineDef?.params?.agentMode == "fast" ? .fast : .auto)

            let registry = AgentToolRegistry(tools: tools)
            let config = AIConfigService.shared
            let activeProviderConfig = ActiveProviderManager.shared.getActiveProvider(context: modelContext)
            let availableModels = activeProviderConfig.flatMap { config.availableModels(for: $0.typeRaw) }

            // Resolve models from ACTUAL provider availability — no hardcoded fallbacks.
            // If no provider is configured, both resolve to nil and analysis is skipped.
            let resolvedAnalysisModel = config.resolvedModelFor(feature: "analysis", context: modelContext)
            let resolvedChatModel = config.resolvedModelFor(feature: "chat", context: modelContext)
            let executorModel = resolvedChatModel ?? availableModels?.first ?? ""
            let advisorModel = resolvedAnalysisModel ?? resolvedChatModel ?? availableModels?.first ?? ""

            guard !executorModel.isEmpty, !advisorModel.isEmpty else {
                AppLog.provider.error("ContentPipeline: no available model for analysis — skipping")
                if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                    fresh.status = .transcribed
                    try? modelContext.save()
                }
                return
            }

            let loop = AgentLoop(
                registry: registry, toolContext: toolContext,
                maxIterations: iterationBudget, mode: agentMode,
                executorModel: executorModel, advisorModel: advisorModel
            )

            // Report progress to UI
            var toolLog: [String] = []
            var agentEvents: [PipelineAgentEvent] = []
            pipelineStatus = PipelineProgress(
                itemId: itemID, itemTitle: item.title,
                itemType: item.type.rawValue, phase: "starting",
                currentTool: nil, toolSummary: nil, toolLog: toolLog,
                events: agentEvents, thinkingActive: false)

            // Verify we have content to analyze before launching the agent.
            // Uses the extractionSvc already created in Phase 0 above.
            let availableText = await extractionSvc.bestAvailableText(for: item) ?? ""
            if availableText.trimmingCharacters(in: .whitespaces).isEmpty {
                // Transcription or extraction failed — status was already set by the extraction
                // phase (.failed if transcription failed, .recorded if not yet transcribed).
                // Do NOT override to .draft — that makes items invisible to retry logic.
                AppLog.provider.warning("ContentPipeline: no extractable text for item \(itemID) — pipeline cannot proceed")
                return
            }

            let taskDescription = """
                Process knowledge item with ID: \(itemID.uuidString)

                Item details:
                - Title: \(item.title)
                - Type: \(item.type.rawValue)
                - Status: \(item.status.rawValue)
                \(item.projectID.map { "- Project ID: \($0.uuidString)" } ?? "")
                \(item.durationSeconds.map { "- Duration: \(Int($0))s" } ?? "")
                """

            var lastError: String?
            var attemptCount = 0
            let maxAttempts = pipelineDef?.params?.retryAttempts ?? 2

            while attemptCount < maxAttempts {
                attemptCount += 1
                let retryTaskDescription: String
                if attemptCount == 1 {
                    retryTaskDescription = taskDescription
                } else {
                    retryTaskDescription = """
                        PREVIOUS ATTEMPT FAILED.
                        Error: \(lastError ?? "unknown")

                        ADJUST YOUR STRATEGY:
                        - If the error mentions schema validation, check write_analysis required fields.
                        - If a tool returned an error, try a different tool for the same goal.
                        - If the content is large, process it in smaller parts via run_command.
                        - If stuck, start with extract and describe what you see before analyzing.

                        Original task:
                        \(taskDescription)
                        """
                }
                let stream = loop.runAutonomous(
                    task: retryTaskDescription,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    provider: provider,
                    maxIterations: iterationBudget
                )

                var failed = false
                do {
                    for try await event in stream {
                        switch event {
                        case .toolCallStarted(let name, let id, let args):
                            AppLog.provider.info("Pipeline agent tool [attempt \(attemptCount)]: \(name)")
                            agentEvents.append(
                                PipelineAgentEvent(
                                    id: UUID(), kind: .toolCall, timestamp: Date(),
                                    detail: name, metadata: args))
                            toolLog.append("\(name): \(args.prefix(80))")
                            pipelineStatus = PipelineProgress(
                                itemId: itemID, itemTitle: item.title,
                                itemType: item.type.rawValue, phase: "analyzing",
                                currentTool: name, toolSummary: nil, toolLog: toolLog,
                                events: agentEvents, thinkingActive: false)
                            NotificationCenter.default.post(
                                name: .contentPipelineStageChanged, object: itemID.uuidString,
                                userInfo: ["tool": name, "args": args, "events": agentEvents, "itemTitle": item.title])
                        case .toolCallCompleted(let name, let id, let summary):
                            AppLog.provider.info("Pipeline agent result [attempt \(attemptCount)]: \(name) — \(summary)")
                            agentEvents.append(
                                PipelineAgentEvent(
                                    id: UUID(), kind: .toolResult, timestamp: Date(),
                                    detail: name, metadata: summary))
                            toolLog.append("\(name): \(summary)")
                            pipelineStatus = PipelineProgress(
                                itemId: itemID, itemTitle: item.title,
                                itemType: item.type.rawValue, phase: "analyzing",
                                currentTool: name, toolSummary: summary, toolLog: toolLog,
                                events: agentEvents, thinkingActive: false)
                            NotificationCenter.default.post(
                                name: .contentPipelineStageChanged, object: itemID.uuidString,
                                userInfo: ["tool": name, "summary": summary, "events": agentEvents, "itemTitle": item.title])
                        case .textDelta(let delta):
                            agentEvents.append(
                                PipelineAgentEvent(
                                    id: UUID(), kind: .textDelta, timestamp: Date(),
                                    detail: String(delta.prefix(100)), metadata: nil))
                        case .thinking:
                            pipelineStatus = PipelineProgress(
                                itemId: itemID, itemTitle: item.title,
                                itemType: item.type.rawValue, phase: "analyzing",
                                currentTool: nil, toolSummary: nil, toolLog: toolLog,
                                events: agentEvents, thinkingActive: true)
                            NotificationCenter.default.post(
                                name: .contentPipelineStageChanged, object: itemID.uuidString,
                                userInfo: ["thinking": true, "events": agentEvents, "itemTitle": item.title])
                        case .finished:
                            AppLog.provider.info("Pipeline agent completed for item \(itemID) on attempt \(attemptCount)")
                            agentEvents.append(
                                PipelineAgentEvent(
                                    id: UUID(), kind: .done, timestamp: Date(),
                                    detail: "Agent finished", metadata: nil))
                            pipelineStatus = PipelineProgress(
                                itemId: itemID, itemTitle: item.title,
                                itemType: item.type.rawValue, phase: "completed",
                                currentTool: nil, toolSummary: nil, toolLog: toolLog,
                                events: agentEvents, thinkingActive: false)
                            NotificationCenter.default.post(
                                name: .contentPipelineStageChanged, object: itemID.uuidString,
                                userInfo: ["phase": "completed", "events": agentEvents, "itemTitle": item.title])
                            failed = false
                        case .truncated(let reason, let progress):
                            AppLog.provider.warning("Pipeline agent truncated for item \(itemID): \(reason) (\(progress))")
                            lastError = "Agent truncated: \(reason)"
                            agentEvents.append(
                                PipelineAgentEvent(
                                    id: UUID(), kind: .failed, timestamp: Date(),
                                    detail: "Truncated: \(reason) (\(progress))", metadata: nil))
                            pipelineStatus = PipelineProgress(
                                itemId: itemID, itemTitle: item.title,
                                itemType: item.type.rawValue, phase: "error",
                                currentTool: nil, toolSummary: "Truncated: \(reason)", toolLog: toolLog,
                                events: agentEvents, thinkingActive: false)
                            failed = true
                        case .error(let error):
                            AppLog.provider.error("Pipeline agent error [attempt \(attemptCount)]: \(error.localizedDescription)")
                            lastError = error.localizedDescription
                            agentEvents.append(
                                PipelineAgentEvent(
                                    id: UUID(), kind: .failed, timestamp: Date(),
                                    detail: error.localizedDescription, metadata: nil))
                            pipelineStatus = PipelineProgress(
                                itemId: itemID, itemTitle: item.title,
                                itemType: item.type.rawValue, phase: "error",
                                currentTool: nil, toolSummary: error.localizedDescription, toolLog: toolLog,
                                events: agentEvents, thinkingActive: false)
                            failed = true
                        }
                    }
                } catch {
                    AppLog.provider.error("Pipeline agent stream error [attempt \(attemptCount)]: \(error.localizedDescription)")
                    lastError = error.localizedDescription
                    failed = true
                }

                // Verify: did the agent actually produce valid analysis?
                if !failed {
                    let store = FileArtifactStore()
                    if store.artifactExists(fileName: "analysis.json", meetingId: itemID) {
                        // Schema validation: ensure output matches the project's framework
                        if let projectID = item.projectID,
                            let project = try? ProjectService(context: modelContext).fetch(id: projectID)
                        {
                            let framework = FrameworkService.shared.resolve(for: project)
                            let fileURL = store.itemDirectoryURL(for: itemID).appendingPathComponent("analysis.json")
                            if let data = try? Data(contentsOf: fileURL),
                                let validationError = FrameworkService.validateAnalysis(data: data, against: framework)
                            {
                                // WriteAnalysisTool already gave the agent feedback during the loop.
                                // If we still have validation errors here, the agent couldn't fix them.
                                // Accept the output anyway — partial analysis is better than none.
                                AppLog.provider.warning("Pipeline: analysis.json has residual schema issues after agent feedback loop: \(validationError)")
                            }
                        }
                        // Create DynamicAnalysis from the raw JSON (any keys work)
                        if !failed, let data = try? Data(contentsOf: store.itemDirectoryURL(for: itemID).appendingPathComponent("analysis.json")),
                            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        {
                            let dynamicData = try? JSONEncoder().encode(
                                DynamicAnalysis(
                                    itemId: itemID,
                                    providerId: provider.id,
                                    model: executorModel,
                                    schemaId: "write_analysis",
                                    results: AnalysisResults(storage: json.mapValues { AnyCodable($0) })
                                ))
                            if let dd = dynamicData {
                                try? dd.write(to: store.itemDirectoryURL(for: itemID).appendingPathComponent(AppFileConstants.dynamicAnalysisFileName))
                            }
                        }
                        if !failed {
                            // Mark item as analyzed now that we have valid analysis
                            if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                                fresh.status = .analyzed
                                fresh.analysisProviderId = executorModel
                                try? modelContext.save()
                            }
                            break  // Success — analysis exists and DynamicAnalysis created
                        }
                    } else {
                        // Agent finished but didn't create analysis
                        AppLog.provider.warning("Pipeline attempt \(attemptCount): agent finished but no analysis.json found")
                        lastError =
                            "Agent completed without producing analysis. The model may have failed to call analyze_content or the tool returned an error."
                        failed = true
                    }
                }

                if !failed { break }
                AppLog.provider.warning("Pipeline attempt \(attemptCount) failed, \(maxAttempts - attemptCount) remaining")
                // Backoff between retries — prevents hammering rate-limited APIs.
                // 5s, 15s for attempts 1-3
                if attemptCount < maxAttempts {
                    let delaySeconds = Int(pow(3.0, Double(attemptCount))) * 5
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                }
            }

            if let error = lastError {
                pipelineStatus = PipelineProgress(
                    itemId: itemID, itemTitle: item.title,
                    itemType: item.type.rawValue, phase: "error",
                    currentTool: nil, toolSummary: error, toolLog: toolLog,
                    events: agentEvents, thinkingActive: false)
            }
            // Mark item as processed. On success, clear inboxDate so the
            // Unprocessed badge disappears — item is fully analyzed, no review needed.
            if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                fresh.analysisProviderId = provider.id
                fresh.status = lastError == nil ? .analyzed : .failed
                if lastError == nil { fresh.inboxDate = nil }
                do { try modelContext.save() } catch {
                    AppLog.provider.error("ContentPipeline: critical save failed (analysis status): \(error.localizedDescription)")
                }
            }
            // Update project health after agent completes
            if let pid = item.projectID { ProjectHealthEngine.updateProject(pid, context: modelContext) }
            // Generate embedding for semantic search
            if lastError == nil, let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                let provider = try? ProviderRouter.resolveActive(context: modelContext)
                if let p = provider { try? await EmbeddingPipelineService().ensureEmbedding(for: fresh, using: p) }
            }
            // Index in Spotlight for system-wide search
            if let fresh = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                SpotlightIndexService().indexItem(fresh)
            }
            // Keep status visible so user can see agent trace
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

            NotificationCenter.default.post(
                name: .contentPipelineStageChanged, object: itemID.uuidString,
                userInfo: ["stage": PipelineStage.ingesting.rawValue])
            await ingestionPipeline.ingest(itemID: itemID, projectID: projectID, using: modelContext)
        }
    }

    /// Process a queue entry with async completion gate.
    func processEntry(itemID: UUID, projectID: UUID? = nil, using modelContext: ModelContext? = nil) async {
        let ctx = modelContext ?? ModelContext(modelContainer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: .pipelineCompleted, object: nil, queue: .main) { note in
                guard let completedID = note.object as? String, completedID == itemID.uuidString else { return }
                if let t = token { NotificationCenter.default.removeObserver(t) }
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            process(itemID, using: ctx)
            // Safety timeout: if notification never fires, resume after 120s
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                guard !resumed else { return }
                resumed = true
                if let t = token { NotificationCenter.default.removeObserver(t) }
                continuation.resume()
            }
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

// MARK: - LensCatalogService

@MainActor
final class LensCatalogService {
    static let shared = LensCatalogService()
    private init() {}

    var allLenses: [Lens] { frameworkLenses + analyticalLenses }

    func lenses(in category: LensCategory) -> [Lens] { allLenses.filter { $0.category == category } }
    func resolve(id: String) -> Lens? { allLenses.first { $0.id == id } }

    /// All 8 built-in frameworks, each with its own schema and render hints.
    /// The agent chooses which sections to fill based on content.
    private var frameworkLenses: [Lens] {
        [
            Lens(
                id: "builtin/meeting", name: "Meeting Analysis", description: "Decisions, actions, risks, dates, entities", icon: "mic.fill", category: .domain,
                framework: FrameworkService.meetingFramework),
            Lens(
                id: "builtin/research", name: "Research", description: "Hypotheses, findings, themes, sources", icon: "magnifyingglass", category: .domain,
                framework: FrameworkService.researchFramework),
            Lens(
                id: "builtin/brainstorm", name: "Brainstorm", description: "Ideas, themes, questions, creative exploration", icon: "lightbulb.fill",
                category: .domain, framework: FrameworkService.brainstormFramework),
            Lens(
                id: "builtin/journal", name: "Journal", description: "Themes, mood, people, places, reflections", icon: "book.fill", category: .personal,
                framework: FrameworkService.journalFramework),
            Lens(
                id: "builtin/coaching", name: "Coaching", description: "Competencies, commitments, breakthroughs", icon: "figure.mind.and.body",
                category: .domain, framework: FrameworkService.coachingFramework),
            Lens(
                id: "builtin/legal", name: "Legal Brief", description: "Citations, statutes, depositions, privilege", icon: "building.columns.fill",
                category: .domain, framework: FrameworkService.legalFramework),
            Lens(
                id: "builtin/product", name: "Product Spec", description: "User stories, requirements, bugs, constraints", icon: "hammer.fill",
                category: .domain, framework: FrameworkService.productFramework),
            Lens(
                id: "builtin/blank", name: "Adaptive", description: "AI chooses sections based on content — no fixed template", icon: "doc.fill",
                category: .custom, framework: FrameworkService.blankFramework),
        ]
    }

    private var analyticalLenses: [Lens] {
        let lenses = AIConfigService.shared.config.lenses ?? [:]
        return lenses.compactMap { key, lensJSON in
            guard let name = lensJSON.name else { return nil }
            return Lens(
                id: "lens/\(key)", name: name, description: lensJSON.description ?? "",
                icon: lensJSON.icon ?? "sparkles", category: .analytical, framework: nil,
                systemPromptOverride: lensJSON.systemPrompt, userPromptTemplate: lensJSON.userPrompt)
        }
    }

    func applyLens(_ lens: Lens, to project: Project) {
        if let fw = lens.framework {
            project.frameworkJSON = (try? JSONEncoder().encode(fw)).flatMap { String(data: $0, encoding: .utf8) }
            project.frameworkId = lens.id
        }
        if let override = lens.systemPromptOverride {
            var instructions = project.customInstructions ?? ""
            if !instructions.isEmpty { instructions += "\n\n" }
            instructions += "[Lens: \(lens.name)]\n\(override)"
            project.customInstructions = instructions
        }
    }
}

// MARK: - Framework Service

/// Resolves which ProjectFramework to use for a project.
/// Falls back to builtin/meeting if no custom framework is set.
@MainActor
final class FrameworkService {
    static let shared = FrameworkService()

    private init() {}

    /// Returns all 8 built-in analysis frameworks, keyed by ID.
    /// Used by VFS `/projects/{slug}/config/schemas/` to list available schemas.
    static var allBuiltInFrameworks: [String: ProjectFramework] {
        [
            "meeting": meetingFramework,
            "research": researchFramework,
            "brainstorm": brainstormFramework,
            "journal": journalFramework,
            "coaching": coachingFramework,
            "legal": legalFramework,
            "product": productFramework,
            "blank": blankFramework,
        ]
    }

    /// Looks up a built-in framework by its short name (e.g., "meeting", "research").
    static func builtInFramework(named name: String) -> ProjectFramework? {
        allBuiltInFrameworks[name]
    }

    func resolve(for project: Project) -> ProjectFramework {
        if let json = project.frameworkJSON,
            let data = json.data(using: .utf8),
            let framework = try? JSONDecoder().decode(ProjectFramework.self, from: data)
        {
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
            let json = String(data: data, encoding: .utf8)
        {
            project.frameworkJSON = json
        }
    }

    /// Validate all views in a framework. Returns invalid view IDs.
    func validateViews(_ framework: ProjectFramework) -> [String] {
        framework.views.filter { !$0.isValid }.map(\.id)
    }

    /// Validate analysis JSON against a framework's outputSchema.
    /// Returns nil on success, or an error message describing what's wrong.
    static func validateAnalysis(json: [String: Any], against framework: ProjectFramework) -> String? {
        let schema = framework.itemAnalysis.outputSchema
        // Only enforce required fields if the schema explicitly lists them.
        // When required is nil, all properties are optional (adaptive mode).
        let required = schema.required ?? []

        // Check required fields are present
        for field in required {
            if json[field] == nil {
                return "Missing required field '\(field)'. Required: \(required.joined(separator: ", "))."
            }
        }

        // Check field types against schema
        for (field, prop) in schema.properties {
            guard let value = json[field] else {
                if required.contains(field) { return "Missing required field '\(field)'" }
                continue  // optional field not present, OK
            }

            switch prop.type {
            case "string":
                guard value is String else { return "Field '\(field)' must be a string" }
            case "array":
                guard let arr = value as? [Any] else { return "Field '\(field)' must be an array" }
                // Validate array items if schema specifies item properties
                if let itemProps = prop.items?.properties {
                    for (idx, item) in arr.enumerated() {
                        guard let obj = item as? [String: Any] else {
                            return "Field '\(field)'[\(idx)] must be an object"
                        }
                        for (itemField, itemProp) in itemProps {
                            if obj[itemField] == nil { continue }  // optional
                            switch itemProp.type {
                            case "string": if !(obj[itemField] is String) { return "Field '\(field)'[\(idx)].\(itemField) must be a string" }
                            case "number", "integer":
                                if !(obj[itemField] is NSNumber) && !(obj[itemField] is Int) && !(obj[itemField] is Double) {
                                    return "Field '\(field)'[\(idx)].\(itemField) must be a number"
                                }
                            default: break
                            }
                        }
                    }
                }
            case "object":
                guard value is [String: Any] else { return "Field '\(field)' must be an object" }
            case "number", "integer":
                guard value is NSNumber || value is Int || value is Double else { return "Field '\(field)' must be a number" }
            case "boolean":
                guard value is Bool else { return "Field '\(field)' must be a boolean" }
            default:
                break
            }
        }

        return nil  // valid
    }

    /// Validate analysis JSON bytes against a framework. Convenience wrapper.
    static func validateAnalysis(data: Data, against framework: ProjectFramework) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Analysis file is not valid JSON"
        }
        return validateAnalysis(json: json, against: framework)
    }

    /// Reset a project's framework to the meeting default.
    func restoreDefaults(to project: Project) {
        project.frameworkJSON = nil
        project.frameworkId = "builtin/meeting"
    }

    // MARK: Built-in frameworks

    static var meetingFramework: ProjectFramework {
        let schema = AnalysisOutputSchema(
            type: "object",
            properties: [
                "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                "detailed_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "Detailed summary"),
                "decisions": SchemaProperty(
                    type: "array",
                    items: SchemaItems(
                        type: "object",
                        properties: [
                            "title": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                            "details": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        ]), properties: nil, description: "Decisions made"),
                "action_items": SchemaProperty(
                    type: "array",
                    items: SchemaItems(
                        type: "object",
                        properties: [
                            "task": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                            "owner": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                            "due_date": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        ]), properties: nil, description: "Action items"),
                "risks": SchemaProperty(
                    type: "array",
                    items: SchemaItems(
                        type: "object",
                        properties: [
                            "risk": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                            "details": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        ]), properties: nil, description: "Risks identified"),
                "open_questions": SchemaProperty(
                    type: "array",
                    items: SchemaItems(
                        type: "object",
                        properties: [
                            "question": SchemaProperty(type: "string", items: nil, properties: nil, description: nil)
                        ]), properties: nil, description: "Open questions"),
                "important_dates": SchemaProperty(
                    type: "array",
                    items: SchemaItems(
                        type: "object",
                        properties: [
                            "date": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                            "meaning": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        ]), properties: nil, description: "Important dates"),
                "entities": SchemaProperty(
                    type: "array",
                    items: SchemaItems(
                        type: "object",
                        properties: [
                            "name": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                            "type": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                        ]), properties: nil, description: "Entities mentioned"),
            ], required: ["short_summary"])

        return ProjectFramework(
            id: "builtin/meeting",
            name: "Meeting Analysis",
            description: "Extracts decisions, action items, risks, open questions, dates, and entities from meeting content.",
            itemAnalysis: AnalysisConfig(
                systemPrompt:
                    "You are a meeting intelligence analyst. Extract decisions, action items with owners, risks, open questions, important dates, and mentioned people/systems/organizations. Return only valid JSON.",
                outputSchema: schema,
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "decisions", type: .list, title: "Decisions", icon: "checkmark.shield"),
                    FieldRenderer(field: "action_items", type: .list, title: "Action Items", icon: "checklist"),
                    FieldRenderer(field: "risks", type: .list, title: "Risks", icon: "exclamationmark.triangle"),
                    FieldRenderer(field: "open_questions", type: .list, title: "Open Questions", icon: "questionmark.circle"),
                    FieldRenderer(field: "entities", type: .chips, title: "Mentioned", icon: "tag"),
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
                ViewDefinition(id: "timeline", title: "Timeline", type: .timeline, source: "items"),
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
                systemPrompt:
                    "You are a research analyst. Extract hypotheses, findings, sources cited, methodology notes, open questions, and key themes from this content. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(
                    type: "object",
                    properties: [
                        "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                        "hypotheses": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "statement": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "confidence": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                ]), properties: nil, description: "Hypotheses proposed or tested"),
                        "findings": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "description": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "source": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                ]), properties: nil, description: "Key findings"),
                        "themes": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Key themes"),
                    ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "hypotheses", type: .list, title: "Hypotheses", icon: "lightbulb"),
                    FieldRenderer(field: "findings", type: .list, title: "Findings", icon: "magnifyingglass"),
                    FieldRenderer(field: "themes", type: .chips, title: "Themes", icon: "tag"),
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
                ViewDefinition(id: "timeline", title: "Timeline", type: .timeline, source: "items"),
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
                systemPrompt:
                    "You analyze brainstorming content. Extract ideas, themes, questions raised, and connections between concepts. Do NOT extract decisions or action items. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(
                    type: "object",
                    properties: [
                        "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                        "ideas": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "idea": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "category": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                ]), properties: nil, description: "Ideas generated"),
                        "themes": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Emerging themes"),
                        "questions": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Questions raised"),
                    ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "ideas", type: .list, title: "Ideas", icon: "lightbulb"),
                    FieldRenderer(field: "themes", type: .chips, title: "Themes", icon: "tag"),
                    FieldRenderer(field: "questions", type: .list, title: "Questions", icon: "questionmark.circle"),
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
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges"),
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
                systemPrompt:
                    "You analyze personal journal entries. Extract themes, mood if evident, people mentioned, places, and cross-references to past entries. Do NOT extract decisions or risks. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(
                    type: "object",
                    properties: [
                        "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                        "themes": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Themes"),
                        "people_mentioned": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "People mentioned"),
                        "places": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Places mentioned"),
                    ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "themes", type: .chips, title: "Themes", icon: "tag"),
                    FieldRenderer(field: "people_mentioned", type: .chips, title: "People", icon: "person"),
                    FieldRenderer(field: "places", type: .chips, title: "Places", icon: "mappin"),
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
                ViewDefinition(id: "graph", title: "Connections", type: .graph, source: "edges"),
            ],
            entityKinds: ["theme", "person", "place", "event"],
            edgeTypes: ["relates_to", "follows_up", "references", "contradicts"]
        )
    }

    static var coachingFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/coaching", name: "Coaching",
            description: "Tracks competency demonstrations, behavioral shifts, and session outcomes across coaching engagements.",
            itemAnalysis: AnalysisConfig(
                systemPrompt:
                    "You are a leadership coach analyst. Extract competency demonstrations, behavioral shifts, commitment follow-through, and breakthrough insights. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(
                    type: "object",
                    properties: [
                        "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line session summary"),
                        "competency_demonstrations": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "competency": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "evidence": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "level": SchemaProperty(type: "string", items: nil, properties: nil, description: "demonstrated|developing|absent"),
                                ]), properties: nil, description: "Competencies observed"),
                        "commitments": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "description": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "deadline": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "follow_through": SchemaProperty(
                                        type: "string", items: nil, properties: nil, description: "pending|in_progress|completed|abandoned"),
                                ]), properties: nil, description: "Commitments made"),
                        "aha_moments": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Breakthrough insights"),
                        "next_session": SchemaProperty(type: "string", items: nil, properties: nil, description: "What to prepare for next session"),
                    ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "competency_demonstrations", type: .list, title: "Competencies", icon: "star"),
                    FieldRenderer(field: "commitments", type: .list, title: "Commitments", icon: "checklist"),
                    FieldRenderer(field: "aha_moments", type: .chips, title: "Breakthroughs", icon: "lightbulb"),
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "Track competency growth, commitment completion rates, and emerging themes across coaching sessions.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)),
            views: [
                ViewDefinition(id: "sessions", title: "Sessions", type: .list, source: "items"),
                ViewDefinition(id: "competencies", title: "Competencies", type: .cards, source: "analysis.competency_demonstrations"),
                ViewDefinition(id: "growth", title: "Growth", type: .timeline, source: "items"),
            ],
            entityKinds: ["competency", "commitment", "feedback_type", "behavioral_shift"],
            edgeTypes: ["supports", "contradicts", "references", "relates_to", "precedes", "mentions"]
        )
    }

    static var legalFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/legal", name: "Legal Brief",
            description: "Connects case citations, statutes, depositions, and party positions with full provenance chains.",
            itemAnalysis: AnalysisConfig(
                systemPrompt:
                    "You are a legal analyst. Extract case citations, statute references, party positions, deposition quotes, and privilege indicators. Flag uncertain readings. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(
                    type: "object",
                    properties: [
                        "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                        "case_citations": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "case_name": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "citation": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "relevance": SchemaProperty(type: "string", items: nil, properties: nil, description: "supports|contradicts|distinguishes"),
                                ]), properties: nil, description: "Cases cited"),
                        "deposition_quotes": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "quote": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "witness": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "significance": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                ]), properties: nil, description: "Key deposition quotes"),
                        "statutes": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Statutes referenced"),
                        "privilege_concerns": SchemaProperty(
                            type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Potential privilege issues"),
                    ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "case_citations", type: .list, title: "Cases", icon: "building.columns"),
                    FieldRenderer(field: "deposition_quotes", type: .list, title: "Depositions", icon: "quote.bubble"),
                    FieldRenderer(field: "statutes", type: .chips, title: "Statutes", icon: "book.pages"),
                    FieldRenderer(field: "privilege_concerns", type: .list, title: "Privilege", icon: "lock.shield"),
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "Synthesize legal strategy. Identify conflicting testimonies, supporting precedents, and gaps in evidence.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)),
            views: [
                ViewDefinition(id: "documents", title: "Documents", type: .list, source: "items"),
                ViewDefinition(id: "cases", title: "Cases", type: .cards, source: "analysis.case_citations"),
                ViewDefinition(id: "timeline", title: "Timeline", type: .timeline, source: "items"),
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges"),
            ],
            entityKinds: ["case", "statute", "party", "jurisdiction", "court", "witness"],
            edgeTypes: ["supports", "contradicts", "references", "relates_to", "precedes", "mentions", "distinguishes"]
        )
    }

    static var productFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/product", name: "Product Spec",
            description: "Connects user stories, requirements, constraints, and bugs with full traceability.",
            itemAnalysis: AnalysisConfig(
                systemPrompt:
                    "You are a product analyst. Extract user stories, requirements, technical constraints, bug references, and design decisions. Return only valid JSON.",
                outputSchema: AnalysisOutputSchema(
                    type: "object",
                    properties: [
                        "short_summary": SchemaProperty(type: "string", items: nil, properties: nil, description: "One-line summary"),
                        "user_stories": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "story": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "role": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "criteria": SchemaProperty(type: "string", items: nil, properties: nil, description: "Acceptance criteria"),
                                ]), properties: nil, description: "User stories"),
                        "requirements": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "description": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "priority": SchemaProperty(type: "string", items: nil, properties: nil, description: "P0/P1/P2/P3"),
                                    "source": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                ]), properties: nil, description: "Requirements"),
                        "constraints": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Technical constraints"),
                        "bugs": SchemaProperty(type: "array", items: SchemaItems(type: "string"), properties: nil, description: "Bug IDs referenced"),
                        "design_decisions": SchemaProperty(
                            type: "array",
                            items: SchemaItems(
                                type: "object",
                                properties: [
                                    "decision": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                    "rationale": SchemaProperty(type: "string", items: nil, properties: nil, description: nil),
                                ]), properties: nil, description: "Design decisions"),
                    ], required: ["short_summary"]),
                renderAs: [
                    FieldRenderer(field: "short_summary", type: .card, title: "Summary", icon: "text.alignleft"),
                    FieldRenderer(field: "user_stories", type: .list, title: "Stories", icon: "person.text.rectangle"),
                    FieldRenderer(field: "requirements", type: .list, title: "Requirements", icon: "list.bullet.clipboard"),
                    FieldRenderer(field: "constraints", type: .chips, title: "Constraints", icon: "hammer"),
                    FieldRenderer(field: "design_decisions", type: .list, title: "Decisions", icon: "paintpalette"),
                ]
            ),
            projectSynthesis: SynthesisConfig(
                systemPrompt: "Synthesize product specs. Identify requirement conflicts, missing criteria, and cross-component dependencies.",
                outputSchema: AnalysisOutputSchema(type: "object", properties: [:], required: nil)),
            views: [
                ViewDefinition(id: "specs", title: "Specs", type: .list, source: "items"),
                ViewDefinition(id: "stories", title: "Stories", type: .cards, source: "analysis.user_stories"),
                ViewDefinition(id: "requirements", title: "Reqs", type: .table, source: "analysis.requirements"),
                ViewDefinition(id: "graph", title: "Deps", type: .graph, source: "edges"),
            ],
            entityKinds: ["story", "requirement", "constraint", "component", "bug"],
            edgeTypes: ["supports", "contradicts", "references", "relates_to", "precedes", "blockedBy", "produces"]
        )
    }

    static var blankFramework: ProjectFramework {
        ProjectFramework(
            id: "builtin/blank",
            name: "Blank",
            description: "Minimal schema. The AI will adapt analysis to whatever content you add.",
            itemAnalysis: AnalysisConfig(
                systemPrompt:
                    "Analyze this content and extract whatever is most relevant. Return a JSON object with fields that make sense for this specific content. Include at least a 'short_summary' string field.",
                outputSchema: AnalysisOutputSchema(
                    type: "object",
                    properties: [
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
                ViewDefinition(id: "graph", title: "Graph", type: .graph, source: "edges"),
            ],
            entityKinds: [],
            edgeTypes: ["relates_to", "references"]
        )
    }
}

// MARK: - Project Health Engine (Phase A)

enum ProjectHealthEngine {
    struct HealthResult {
        let score: Int
        let status: String
        let decisionVelocity: Double
        let actionDebtRatio: Double
        let evidenceFreshnessDays: Double
        let graphDensity: Double
        let riskExposure: Double
        let anomalies: [String]
    }
    @MainActor
    static func compute(for projectID: UUID, context: ModelContext) -> HealthResult? {
        guard (try? ProjectService(context: context).fetch(id: projectID)) != nil else { return nil }
        let items = (try? ProjectService(context: context).items(in: projectID)) ?? []
        let tasks = (try? TaskService(context: context).tasks(for: projectID)) ?? []
        // Signal counts
        let allSignals = (try? context.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        let projectSignals = allSignals.filter { $0.projectID == projectID }
        let pendingSignals = projectSignals.filter { $0.isActive }
        let unresolvedRisks = pendingSignals.filter { $0.type == "risk" || $0.type == "alert" }
        let edgeSvc = GraphEdgeService(context: context)
        let itemIDs = Set(items.map(\.id))
        let allEdges = (try? edgeSvc.recentEdges(limit: 500))?.filter { itemIDs.contains($0.fromID) || itemIDs.contains($0.toID) } ?? []
        var decisionCount = 0
        var riskCount = 0
        var totalRiskSeverity = 0.0
        let store = FileArtifactStore()
        let fourWeeksAgo = Date().addingTimeInterval(-28 * 86400)
        var recentDecisionCount = 0
        for item in items {
            guard let a = try? store.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: item.id) else { continue }
            decisionCount += a.decisions.count
            riskCount += a.risks.count
            let isRecent = item.createdAt >= fourWeeksAgo
            if isRecent { recentDecisionCount += a.decisions.count }
            totalRiskSeverity += a.risks.map { ($0.confidence ?? 0.5) }.reduce(0, +)
        }
        // Decisions per week over last 4 weeks (temporal)
        let decisionVelocity = Double(recentDecisionCount) / 4.0
        // Risk exposure: magnitude (count × avg severity), normalized 0-1
        let avgSeverity = riskCount > 0 ? totalRiskSeverity / Double(riskCount) : 0
        let maxRisks = 20.0
        let riskMagnitude = min(Double(riskCount) / maxRisks, 1.0)
        let riskExposure = riskMagnitude * avgSeverity
        let totalTasks = tasks.count
        let openTasks = tasks.filter { $0.status == .todo || $0.status == .inProgress }.count
        let actionDebtRatio = totalTasks > 0 ? Double(openTasks) / Double(totalTasks) : 0
        let now = Date()
        let ages = items.map { now.timeIntervalSince($0.createdAt) / 86400 }.sorted()
        let medianAge: Double = ages.isEmpty ? -1 : (ages.count % 2 == 0 ? (ages[ages.count / 2 - 1] + ages[ages.count / 2]) / 2 : ages[ages.count / 2])
        let entityCount = Set(allEdges.flatMap { [$0.fromID, $0.toID] }).count
        let graphDensity = entityCount > 1 ? Double(allEdges.count) / Double(entityCount * (entityCount - 1)) : 0
        let dv = min(decisionVelocity / 2.0, 1.0) * 25
        let ad = (1.0 - actionDebtRatio) * 25.0
        let ef = medianAge < 7 ? 20.0 : medianAge < 14 ? 15.0 : medianAge < 30 ? 10.0 : 5.0
        let gd = graphDensity > 0.10 ? 15.0 : graphDensity > 0.05 ? 10.0 : 5.0
        let re = (1.0 - riskExposure) * 15.0
        let score = Int((dv + ad + ef + gd + re).rounded())
        let status = score >= 70 ? "healthy" : score >= 40 ? "stale" : score >= 30 ? "atRisk" : "dormant"
        var anomalies: [String] = []
        if medianAge < 0 { anomalies.append("No items in project") } else if medianAge > 7 { anomalies.append("Silence burst: \(Int(medianAge))d") }
        if decisionVelocity < 0.5 && items.count >= 3 { anomalies.append("Decision drought") }
        if actionDebtRatio > 0.7 && totalTasks > 0 { anomalies.append("Action debt: \(Int(actionDebtRatio*100))%") }
        if riskExposure > 0.5 { anomalies.append("High risk exposure") }
        if unresolvedRisks.count > 0 { anomalies.append("Unresolved risks: \(unresolvedRisks.count)") }
        if pendingSignals.count >= 5 { anomalies.append("Signal backlog: \(pendingSignals.count) pending") }
        return HealthResult(
            score: score, status: status, decisionVelocity: decisionVelocity, actionDebtRatio: actionDebtRatio, evidenceFreshnessDays: medianAge,
            graphDensity: graphDensity, riskExposure: riskExposure, anomalies: anomalies)
    }
    @MainActor
    static func updateProject(_ pid: UUID, context: ModelContext) {
        guard let r = compute(for: pid, context: context), let p = try? ProjectService(context: context).fetch(id: pid) else { return }
        p.healthScore = Double(r.score)
        p.healthStatus = r.status
        p.lastActivityAt = Date()
        try? context.save()
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

// MARK: - Pipeline progress (observable)

/// An individual event in the agent's processing trace, rendered in the UI.
struct PipelineAgentEvent: Sendable, Identifiable {
    enum Kind: String, Sendable {
        case thinking  // Agent is reasoning (LLM thinking)
        case toolCall  // Agent called a tool
        case toolResult  // Tool returned a result
        case textDelta  // Agent sent a text chunk
        case done  // Agent finished successfully
        case failed  // Agent errored
    }
    let id: UUID
    let kind: Kind
    let timestamp: Date
    let detail: String  // tool name, summary, or thinking label
    let metadata: String?  // arguments, full result, or thinking text
}

struct PipelineProgress: Sendable {
    let itemId: UUID
    let itemTitle: String
    let itemType: String
    let phase: String  // "starting", "transcribing", "analyzing", "ingesting", "completed", "error"
    let currentTool: String?
    let toolSummary: String?
    var toolLog: [String]  // ordered list of "tool_name: summary"
    var events: [PipelineAgentEvent]  // full agent trace for UI rendering
    var thinkingActive: Bool  // true when agent is in thinking/reasoning state
}

// MARK: - Editable Prompt

struct EditablePrompt: Codable, Sendable {
    let name: String
    let category: String
    var content: String
    var description: String?
    var variables: [String]
    var updatedAt: Date
    var isUserEdited: Bool
}

// MARK: - Prompt Store

/// Persists user-editable prompts. Reads base prompts from ai_config.json,
/// applies user overrides from prompts.json.
@MainActor
final class PromptStore: ObservableObject {
    static let shared = PromptStore()

    @Published private(set) var prompts: [String: EditablePrompt] = [:]
    private let fileStore = FileArtifactStore()
    private let fileManager = FileManager.default

    private var overridesURL: URL {
        fileStore.configsDirectoryURL().appendingPathComponent("prompts.json")
    }

    private init() {
        loadBasePrompts()
        applyUserOverrides()
    }

    private func loadBasePrompts() {
        guard let url = Bundle.main.url(forResource: "ai_config", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let features = json["features"] as? [String: [String: Any]]
        else { return }

        let now = Date()
        for (featureKey, featureDict) in features {
            let systemPrompt = featureDict["systemPrompt"] as? String ?? ""
            let userPrompt = featureDict["userPrompt"] as? String ?? ""
            let category = Self.mapCategory(featureKey)

            if !systemPrompt.isEmpty {
                prompts["\(featureKey)_system"] = EditablePrompt(
                    name: "\(featureKey)_system", category: category,
                    content: systemPrompt,
                    description: "System prompt for \(featureKey)",
                    variables: extractVariables(from: systemPrompt + userPrompt),
                    updatedAt: now, isUserEdited: false
                )
            }

            if !userPrompt.isEmpty {
                prompts["\(featureKey)_user"] = EditablePrompt(
                    name: "\(featureKey)_user", category: category,
                    content: userPrompt,
                    description: "User prompt template for \(featureKey)",
                    variables: extractVariables(from: systemPrompt + userPrompt),
                    updatedAt: now, isUserEdited: false
                )
            }
        }

        // Pipeline templates
        prompts["pipeline_standard"] = EditablePrompt(
            name: "pipeline_standard", category: "pipeline",
            content: PipelineTemplate.standard,
            description: "Standard content processing pipeline",
            variables: ["item_id", "item_type"],
            updatedAt: now, isUserEdited: false
        )
    }

    private func applyUserOverrides() {
        guard fileManager.fileExists(atPath: overridesURL.path),
            let data = try? Data(contentsOf: overridesURL),
            let overrides = try? JSONDecoder().decode([String: EditablePrompt].self, from: data)
        else { return }
        for (key, prompt) in overrides where prompt.isUserEdited {
            prompts[key] = prompt
        }
    }

    private func saveOverrides() {
        let overrides = prompts.filter { $0.value.isUserEdited }
        guard !overrides.isEmpty else {
            try? fileManager.removeItem(at: overridesURL)
            return
        }
        do {
            try fileManager.createDirectory(at: overridesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(overrides)
            try data.write(to: overridesURL, options: .atomic)
        } catch {
            AppLog.provider.error("PromptStore: failed to save overrides: \(error)")
        }
    }

    // MARK: - CRUD

    func prompt(named name: String) -> EditablePrompt? { prompts[name] }

    func prompts(in category: String? = nil) -> [EditablePrompt] {
        let all = Array(prompts.values)
        guard let cat = category else { return all.sorted { $0.name < $1.name } }
        return all.filter { $0.category == cat }.sorted { $0.name < $1.name }
    }

    func updatePrompt(named name: String, content: String) {
        guard var prompt = prompts[name] else { return }
        prompt.content = content
        prompt.updatedAt = Date()
        prompt.isUserEdited = true
        prompts[name] = prompt
        saveOverrides()
    }

    func createPrompt(name: String, category: String, content: String, description: String? = nil) -> EditablePrompt {
        let prompt = EditablePrompt(
            name: name, category: category, content: content,
            description: description, variables: extractVariables(from: content),
            updatedAt: Date(), isUserEdited: true
        )
        prompts[name] = prompt
        saveOverrides()
        return prompt
    }

    func resetPrompt(named name: String) {
        prompts[name]?.isUserEdited = false
        saveOverrides()
        loadBasePrompts()
        applyUserOverrides()
    }

    func resolvedSystemPrompt(for feature: String) -> String {
        prompts["\(feature)_system"]?.content ?? ""
    }

    func resolvedUserPrompt(for feature: String) -> String {
        prompts["\(feature)_user"]?.content ?? ""
    }

    // MARK: - Helpers

    private static func mapCategory(_ featureKey: String) -> String {
        switch featureKey {
        case "analysis", "cross_reference", "co_creation": return "analysis"
        case "chat": return "chat"
        case "transcription": return "system"
        default: return "custom"
        }
    }

    private func extractVariables(from template: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "\\{(\\w+)\\}")
        let matches = pattern?.matches(in: template, range: NSRange(template.startIndex..., in: template)) ?? []
        return matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: template) else { return nil }
            return String(template[range])
        }
    }
}

// MARK: - Agent Memory

/// A learned pattern or strategy that the agent can recall.
struct AgentMemory: Codable, Identifiable, Sendable {
    var id: UUID
    let pattern: String  // e.g. "audio > 60min in Portuguese"
    let strategy: String  // e.g. "chunk 5k chars with nano, reduce with gpt-5.5"
    let itemType: String?  // "audio", "image", "note"
    let contentType: String?  // "meeting", "interview", "document", "photo"
    let language: String?  // "pt", "en", etc.
    let minDuration: Double?  // seconds
    let minChars: Int?  // character count threshold
    var successCount: Int
    var failCount: Int
    var lastUsed: Date
    let createdAt: Date
    var isStale: Bool  // >3 consecutive failures

    var relevance: Double {
        let total = Double(successCount + failCount)
        guard total > 0 else { return 0 }
        return Double(successCount) / total
    }
}

/// Persists agent learnings as JSON. Before processing content, the agent
/// searches for memories with similar characteristics to apply proven strategies.
@MainActor
final class AgentMemoryStore: ObservableObject {
    static let shared = AgentMemoryStore()

    @Published private(set) var memories: [AgentMemory] = []
    private let fileStore = FileArtifactStore()
    private let fileManager = FileManager.default

    private var storeURL: URL {
        fileStore.configsDirectoryURL().appendingPathComponent("agent_memories.json")
    }

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard fileManager.fileExists(atPath: storeURL.path),
            let data = try? Data(contentsOf: storeURL),
            let loaded = try? JSONDecoder().decode([AgentMemory].self, from: data)
        else { return }
        memories = loaded
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(memories)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            AppLog.provider.error("AgentMemoryStore: save failed: \(error)")
        }
    }

    // MARK: - CRUD

    func write(
        pattern: String, strategy: String, itemType: String? = nil,
        contentType: String? = nil, language: String? = nil,
        minDuration: Double? = nil, minChars: Int? = nil
    ) -> AgentMemory {
        let mem = AgentMemory(
            id: UUID(), pattern: pattern, strategy: strategy,
            itemType: itemType, contentType: contentType, language: language,
            minDuration: minDuration, minChars: minChars,
            successCount: 1, failCount: 0,
            lastUsed: Date(), createdAt: Date(), isStale: false
        )
        memories.append(mem)
        save()
        return mem
    }

    func recordSuccess(id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].successCount += 1
        memories[idx].lastUsed = Date()
        memories[idx].isStale = false
        save()
    }

    func recordFailure(id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].failCount += 1
        memories[idx].lastUsed = Date()
        if memories[idx].failCount >= 3 { memories[idx].isStale = true }
        save()
    }

    /// Search for relevant memories matching content characteristics.
    func search(
        itemType: String? = nil, language: String? = nil,
        minDuration: Double? = nil, minChars: Int? = nil,
        contentType: String? = nil, maxResults: Int = 5
    ) -> [AgentMemory] {
        memories
            .filter { !$0.isStale }
            .filter { mem in
                if let t = itemType, mem.itemType != nil, mem.itemType != t { return false }
                if let l = language, mem.language != nil, mem.language != l { return false }
                if let d = minDuration, let memDur = mem.minDuration, memDur < d { return false }
                if let ch = minChars, let memCh = mem.minChars, memCh < ch { return false }
                if let ct = contentType, mem.contentType != nil, mem.contentType != ct { return false }
                return true
            }
            .sorted { $0.relevance > $1.relevance }
            .prefix(maxResults)
            .map { $0 }
    }

    func listAll() -> [AgentMemory] {
        memories.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Link a memory to the knowledge item that generated it via Annotation.
    func linkToItem(memoryId: UUID, itemId: UUID, context: ModelContext) {
        guard let mem = memories.first(where: { $0.id == memoryId }) else { return }
        let annotationService = AnnotationService(context: context)
        try? annotationService.upsert(
            [
                CapturedAnnotation(source: "agent_memory", key: "memory_id", value: memoryId.uuidString, confidence: 1.0),
                CapturedAnnotation(source: "agent_memory", key: "pattern", value: mem.pattern, confidence: nil),
                CapturedAnnotation(source: "agent_memory", key: "strategy", value: mem.strategy, confidence: nil),
            ], itemID: itemId, source: "agent_memory")
    }
}

// MARK: - Tool Permissions (Phase 5)

enum ToolPermission {
    case readOnly
    case write
    case destructive

    /// Classify a tool by name. Write and destructive tools require confirmation in interactive mode.
    static func classify(toolName: String) -> ToolPermission {
        switch toolName {
        case "search_knowledge", "get_item", "list_items", "get_project",
            "get_connections", "get_tasks", "get_analysis", "summarize_day",
            "read_prompt", "list_prompts", "search_memory", "list_memories",
            "extract_content", "describe_image":
            return .readOnly
        case "create_note", "create_task", "update_task", "create_edge",
            "set_annotation", "analyze_content", "edit_prompt",
            "write_memory", "create_project_framework", "update_project_framework",
            "raise_signal", "list_lenses", "apply_lens":
            return .write
        case "trash_item":
            return .destructive
        default:
            return .write
        }
    }

    var requiresConfirmation: Bool {
        switch self {
        case .readOnly: return false
        case .write: return false  // Pipeline auto-approves; interactive chat may override
        case .destructive: return true
        }
    }
}

// MARK: - Output Blocks (UI contract)

/// Structured output blocks that the UI renders natively.
/// Models can produce these via output tools (render_table, render_actions, etc.)
/// or the ContentParser falls back to heuristic markdown parsing.
enum OutputBlock: Identifiable, Sendable {
    case text(String)
    case table(TableBlock)
    case actions(ActionBlock)
    case card(CardBlock)
    case bulletList([String])
    case orderedList([String])
    case code(CodeBlock)

    var id: String { UUID().uuidString }
}

struct TableBlock: Sendable {
    let title: String?
    let headers: [String]
    let rows: [[String]]
}

struct ActionBlock: Sendable {
    let title: String?
    let items: [ActionBlockItem]
}

struct ActionBlockItem: Sendable {
    let task: String
    let owner: String?
    let dueDate: String?
    let priority: String?
}

struct CardBlock: Sendable {
    let title: String
    let body: String
    let entities: [String]
    let badge: String?
}

struct CodeBlock: Sendable {
    let code: String
    let language: String?
    let caption: String?
}

struct ParseError: Sendable {
    let line: Int
    let snippet: String
    let reason: String
    let suggestion: String
}

// MARK: - Content Parser (heuristic fallback)

/// Parses markdown/model output into OutputBlocks heuristically.
/// When the model doesn't use output tools, this extracts structure from raw text.
/// ParseErrors are returned for the model to fix in a feedback loop.
enum ContentParser {
    static func parse(_ text: String) -> (blocks: [OutputBlock], errors: [ParseError]) {
        var blocks: [OutputBlock] = []
        var errors: [ParseError] = []

        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Skip empty
            if line.isEmpty {
                i += 1
                continue
            }

            // Table detection: lines with | separators
            if line.contains("|") && line.hasPrefix("|") {
                let (tableBlock, consumed, parseErrors) = parseTable(from: lines, startIndex: i)
                if let tb = tableBlock { blocks.append(.table(tb)) }
                errors.append(contentsOf: parseErrors)
                i += consumed
                continue
            }

            // Action item: "- [ ] task | owner: X | due: Y"
            if line.hasPrefix("- [ ]") || line.hasPrefix("* [ ]") {
                let (actionBlock, consumed) = parseActionItems(from: lines, startIndex: i)
                if let ab = actionBlock { blocks.append(.actions(ab)) }
                i += consumed
                continue
            }

            // Code block: ```
            if line.hasPrefix("```") {
                let (codeBlock, consumed) = parseCodeBlock(from: lines, startIndex: i)
                if let cb = codeBlock { blocks.append(.code(cb)) }
                i += consumed
                continue
            }

            // Bullet list: consecutive "- " or "* " lines (not action items)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let (listBlock, consumed) = parseBulletList(from: lines, startIndex: i)
                if let items = listBlock { blocks.append(.bulletList(items)) }
                i += consumed
                continue
            }

            // Ordered list: "1. ", "2. "
            if line.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                let (listBlock, consumed) = parseOrderedList(from: lines, startIndex: i)
                if let items = listBlock { blocks.append(.orderedList(items)) }
                i += consumed
                continue
            }

            // Default: text — accumulate consecutive text lines
            var textLines: [String] = []
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l.hasPrefix("```") || l.hasPrefix("|") || l.hasPrefix("- [ ]") || l.hasPrefix("* [ ]") || l.hasPrefix("- ") || l.hasPrefix("* ")
                    || l.range(of: #"^\d+\."#, options: .regularExpression) != nil
                {
                    break
                }
                textLines.append(lines[i])
                i += 1
            }
            if !textLines.isEmpty {
                blocks.append(.text(textLines.joined(separator: "\n")))
            }
        }

        return (blocks, errors)
    }

    // MARK: Table parser

    private static func parseTable(from lines: [String], startIndex: Int) -> (TableBlock?, Int, [ParseError]) {
        var errors: [ParseError] = []
        var tableLines: [String] = []
        var i = startIndex

        // Collect all consecutive lines starting with |
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { break }
            tableLines.append(line)
            i += 1
        }

        guard tableLines.count >= 2 else {
            errors.append(
                ParseError(
                    line: startIndex + 1, snippet: tableLines.first ?? "",
                    reason: "Table needs at least 2 rows (header + separator)", suggestion: "Add a separator row: |---|---|"))
            return (nil, tableLines.count, errors)
        }

        // Parse header
        let headerCells = parseTableRow(tableLines[0])
        guard !headerCells.isEmpty else {
            errors.append(
                ParseError(
                    line: startIndex + 1, snippet: tableLines[0],
                    reason: "Could not parse table header", suggestion: "Format: | Col1 | Col2 |"))
            return (nil, tableLines.count, errors)
        }

        // Skip separator row (|---|---|)
        var dataStart = 1
        if tableLines.count > 1 && tableLines[1].contains("---") {
            dataStart = 2
        }

        // Parse data rows
        var rows: [[String]] = []
        for rowIdx in dataStart..<tableLines.count {
            let cells = parseTableRow(tableLines[rowIdx])
            if cells.count != headerCells.count {
                errors.append(
                    ParseError(
                        line: startIndex + rowIdx + 1, snippet: tableLines[rowIdx],
                        reason: "Row has \(cells.count) columns, expected \(headerCells.count)",
                        suggestion: "Each row must have exactly \(headerCells.count) cells matching: \(headerCells.joined(separator: " | "))"))
            }
            rows.append(cells)
        }

        return (TableBlock(title: nil, headers: headerCells, rows: rows), tableLines.count, errors)
    }

    private static func parseTableRow(_ line: String) -> [String] {
        // Split by | and trim, skip empty first/last from leading/trailing |
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Remove leading empty if line started with |
        // Remove trailing empty if line ended with |
        let start = cells.first?.isEmpty == true ? 1 : 0
        let end = cells.last?.isEmpty == true ? cells.count - 1 : cells.count
        guard start < end else { return [] }
        return Array(cells[start..<end])
    }

    // MARK: Action item parser

    private static func parseActionItems(from lines: [String], startIndex: Int) -> (ActionBlock?, Int) {
        var items: [ActionBlockItem] = []
        var i = startIndex

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- [ ]") || line.hasPrefix("* [ ]") else { break }

            let content = line.replacingOccurrences(of: "- [ ]", with: "")
                .replacingOccurrences(of: "* [ ]", with: "")
                .trimmingCharacters(in: .whitespaces)

            var task = content
            var owner: String? = nil
            var dueDate: String? = nil
            var priority: String? = nil

            // Extract metadata: "task | owner: name | due: date | priority: high"
            let parts = content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                task = parts[0]
                for part in parts.dropFirst() {
                    if part.hasPrefix("owner:") {
                        owner = part.replacingOccurrences(of: "owner:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if part.hasPrefix("due:") {
                        dueDate = part.replacingOccurrences(of: "due:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if part.hasPrefix("priority:") {
                        priority = part.replacingOccurrences(of: "priority:", with: "").trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            items.append(ActionBlockItem(task: task, owner: owner, dueDate: dueDate, priority: priority))
            i += 1
        }

        if items.isEmpty { return (nil, 1) }
        return (ActionBlock(title: nil, items: items), i - startIndex)
    }

    // MARK: Code block parser

    private static func parseCodeBlock(from lines: [String], startIndex: Int) -> (CodeBlock?, Int) {
        var i = startIndex + 1  // skip opening ```
        var codeLines: [String] = []
        let lang = lines[startIndex].replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespaces)

        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                i += 1
                break
            }
            codeLines.append(lines[i])
            i += 1
        }

        let code = codeLines.joined(separator: "\n")
        guard !code.isEmpty else { return (nil, i - startIndex) }
        return (CodeBlock(code: code, language: lang.isEmpty ? nil : lang, caption: nil), i - startIndex)
    }

    // MARK: Bullet list parser

    private static func parseBulletList(from lines: [String], startIndex: Int) -> ([String]?, Int) {
        var items: [String] = []
        var i = startIndex

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard (line.hasPrefix("- ") || line.hasPrefix("* ")) && !line.hasPrefix("- [ ]") && !line.hasPrefix("* [ ]") else { break }
            items.append(String(line.dropFirst(2)))
            i += 1
        }

        if items.isEmpty { return (nil, 1) }
        return (items, i - startIndex)
    }

    // MARK: Ordered list parser

    private static func parseOrderedList(from lines: [String], startIndex: Int) -> ([String]?, Int) {
        var items: [String] = []
        var i = startIndex

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: #"^\d+\."#, options: .regularExpression) else { break }
            items.append(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            i += 1
        }

        if items.isEmpty { return (nil, 1) }
        return (items, i - startIndex)
    }
}

// MARK: - Skill Template (Phase 4)

/// A reusable agent template that can be spawned as a sub-agent.
struct SkillTemplate: Codable, Identifiable, Sendable {
    var id: UUID
    let name: String
    let description: String
    let systemPrompt: String
    let allowedTools: [String]
    let defaultModel: String
    let maxIterations: Int

    static let builtIn: [SkillTemplate] = [
        SkillTemplate(
            id: UUID(), name: "deep_research",
            description: "Multi-item search and synthesis across the entire knowledge base",
            systemPrompt:
                "You are a research agent. Search the knowledge base thoroughly, read relevant items, and synthesize findings. Be thorough — explore connections between items. Output a structured research report.",
            allowedTools: ["search_knowledge", "get_item", "list_items", "get_project", "get_connections", "get_analysis"],
            defaultModel: "gpt-5.5", maxIterations: 15
        ),
        SkillTemplate(
            id: UUID(), name: "quick_extract",
            description: "Extract text only — no AI analysis. Fast and cheap.",
            systemPrompt: "You are a content extraction agent. Extract text from the item and return it. Do NOT run analysis.",
            allowedTools: ["extract_content", "describe_image"],
            defaultModel: "gpt-5-nano", maxIterations: 3
        ),
        SkillTemplate(
            id: UUID(), name: "meeting_summarizer",
            description: "Focus on decisions, action items, and key outcomes from meetings",
            systemPrompt:
                "You are a meeting analyst. Focus on: who attended, what was decided, action items with owners, and follow-ups. Be concise and actionable.",
            allowedTools: ["extract_content", "analyze_content", "create_task"],
            defaultModel: "gpt-5.5", maxIterations: 8
        ),
    ]
}

// MARK: - JS Sandbox (JavaScriptCore bridge)

@objc @MainActor protocol WawaJSExports: JSExport {
    // Knowledge
    func getAllItems() -> [[String: Any]]
    func searchItems(_ query: String) -> [[String: Any]]
    func getItem(_ id: String) -> [String: Any]?
    func getItemAnalysis(_ id: String) -> [String: Any]?
    func getProject(_ id: String) -> [String: Any]?
    func getProjectTasks(_ projectId: String) -> [[String: Any]]
    func createTask(_ title: String, owner: String?, due: String?, projectId: String?) -> [String: Any]
    func jsLog(_ message: String)
    func jsNow() -> String
    // Document I/O
    func readPDF(_ itemId: String) -> String?
    func readExcel(_ itemId: String) -> [[String: Any]]?
    func readWord(_ itemId: String) -> String?
    func listFiles(_ itemId: String) -> [String]
    // Chart data
    func chartData(_ data: [[String: Any]], type: String, labels: [String]) -> [String: Any]
}

@MainActor
final class WawaJSBridge: NSObject, WawaJSExports {
    private let modelContext: ModelContext
    private let fileStore: FileArtifactStore
    nonisolated(unsafe) var logs: [String] = []

    init(modelContext: ModelContext, fileStore: FileArtifactStore) {
        self.modelContext = modelContext
        self.fileStore = fileStore
        super.init()
    }

    func getAllItems() -> [[String: Any]] {
        let svc = KnowledgeItemService(context: modelContext)
        return ((try? svc.allItems()) ?? []).map(itemToDict)
    }

    func searchItems(_ query: String) -> [[String: Any]] {
        let svc = KnowledgeItemService(context: modelContext)
        let items = (try? svc.allItems()) ?? []
        let results = SearchService().searchNow(query: query, in: items)
        return results.compactMap { r in
            guard let item = items.first(where: { $0.id == r.itemID }) else { return nil }
            var d = itemToDict(item)
            d["snippet"] = r.snippet
            d["matchedField"] = r.matchedField.rawValue
            return d
        }
    }

    func getItem(_ id: String) -> [String: Any]? {
        guard let uuid = UUID(uuidString: id),
            let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: uuid)
        else { return nil }
        return itemToDict(item)
    }

    func getItemAnalysis(_ id: String) -> [String: Any]? {
        guard let uuid = UUID(uuidString: id),
            let analysis = try? fileStore.readArtifact(MeetingAnalysis.self, fileName: "analysis.json", meetingId: uuid)
        else { return nil }
        return [
            "shortSummary": analysis.shortSummary,
            "detailedSummary": analysis.detailedSummary,
            "decisions": analysis.decisions.map { ["title": $0.title, "details": $0.details] },
            "actionItems": analysis.actionItems.map { ["task": $0.task, "owner": $0.owner ?? ""] },
            "risks": analysis.risks.map { ["risk": $0.risk, "confidence": $0.confidence ?? 0] },
            "openQuestions": analysis.openQuestions.map { ["question": $0.question] },
        ]
    }

    func getProject(_ id: String) -> [String: Any]? {
        guard let uuid = UUID(uuidString: id),
            let project = try? ProjectService(context: modelContext).fetch(id: uuid)
        else { return nil }
        return ["id": project.id.uuidString, "name": project.name]
    }

    func getProjectTasks(_ projectId: String) -> [[String: Any]] {
        guard let uuid = UUID(uuidString: projectId) else { return [] }
        let tasks = (try? TaskService(context: modelContext).tasks(for: uuid)) ?? []
        return tasks.map { t in ["id": t.id.uuidString, "title": t.title, "status": t.status.rawValue, "priority": t.priority.rawValue] }
    }

    func createTask(_ title: String, owner: String?, due: String?, projectId: String?) -> [String: Any] {
        let dueDate = due.flatMap { ISO8601DateFormatter().date(from: $0) }
        let pid = projectId.flatMap(UUID.init(uuidString:))
        let task = TaskItem(projectID: pid, title: title, ownerName: owner, dueAt: dueDate)
        modelContext.insert(task)
        try? modelContext.save()
        return ["id": task.id.uuidString, "title": task.title, "status": "todo"]
    }

    func jsLog(_ message: String) {
        logs.append(message)
        AppLog.general.info("[JS] \(message)")
    }

    func jsNow() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: Document I/O

    func readPDF(_ itemId: String) -> String? {
        guard let uuid = UUID(uuidString: itemId) else { return nil }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        let pdfs =
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension.lowercased() == "pdf"
            } ?? []
        guard let pdfURL = pdfs.first,
            let pdf = PDFDocument(url: pdfURL)
        else { return nil }
        return pdf.string
    }

    func readExcel(_ itemId: String) -> [[String: Any]]? {
        // Try CSV first (pure Swift), then xlsx via base64 bridge
        guard let uuid = UUID(uuidString: itemId),
            let item = try? KnowledgeItemService(context: modelContext).fetchItem(id: uuid),
            let text = item.bodyText ?? loadFileText(itemId: itemId, ext: "csv")
        else { return nil }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let headers = lines[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.dropFirst().map { line in
            let cells = line.components(separatedBy: ",")
            var row: [String: Any] = [:]
            for (i, h) in headers.enumerated() {
                row[h] = i < cells.count ? cells[i].trimmingCharacters(in: .whitespaces) : ""
            }
            return row
        }
    }

    func readWord(_ itemId: String) -> String? {
        guard let uuid = UUID(uuidString: itemId) else { return nil }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        let docs =
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "docx" || ext == "rtf" || ext == "txt"
            } ?? []
        guard let docURL = docs.first else { return nil }
        if docURL.pathExtension.lowercased() == "txt" {
            return try? String(contentsOf: docURL, encoding: .utf8)
        }
        if let rtf = try? NSAttributedString(url: docURL, options: [:], documentAttributes: nil) {
            return rtf.string
        }
        return try? String(contentsOf: docURL, encoding: .utf8)
    }

    func listFiles(_ itemId: String) -> [String] {
        guard let uuid = UUID(uuidString: itemId) else { return [] }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.map { $0.lastPathComponent } ?? []
    }

    private func loadFileText(itemId: String, ext: String) -> String? {
        guard let uuid = UUID(uuidString: itemId) else { return nil }
        let dir = fileStore.itemDirectoryURL(for: uuid)
        let files =
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension.lowercased() == ext
            } ?? []
        guard let url = files.first else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Chart data (returns structured data for native rendering)

    func chartData(_ data: [[String: Any]], type: String, labels: [String]) -> [String: Any] {
        // Returns chart config for Swift Charts renderer
        return ["type": type, "labels": labels, "data": data]
    }

    // MARK: Helpers

    private func itemToDict(_ item: KnowledgeItem) -> [String: Any] {
        [
            "id": item.id.uuidString, "title": item.title, "type": item.type.rawValue,
            "status": item.status.rawValue, "createdAt": item.createdAt.description,
            "durationSeconds": item.durationSeconds ?? 0, "tags": item.tags,
            "projectID": item.projectID?.uuidString ?? "",
        ]
    }
}

enum JSSandbox {
    static let timeout: TimeInterval = 5.0

    struct Result {
        let output: String
        let logs: [String]
        let error: String?
    }

    static func execute(_ code: String, bridge: WawaJSBridge) -> Result {
        guard let context = JSContext() else {
            return Result(output: "", logs: [], error: "Could not create JSContext")
        }
        context.setObject(bridge, forKeyedSubscript: "native" as NSString)

        // Inject console shim
        context.evaluateScript(
            """
            var console = {
                log: function(m) { native.jsLog(String(m)); },
                error: function(m) { native.jsLog('[ERROR] ' + String(m)); },
                warn: function(m) { native.jsLog('[WARN] ' + String(m)); }
            };
            """)

        // Inject dayjs (date library, 7KB minified core)
        context.evaluateScript(Self.dayjsCore)

        // Inject simple-statistics
        context.evaluateScript(Self.simpleStats)

        // Inject wawa helpers
        context.evaluateScript(Self.wawaHelpers)

        var jsResult: JSValue?
        var jsError: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            jsResult = context.evaluateScript(code)
            if let exc = context.exception {
                let line = exc.objectForKeyedSubscript("line")?.toInt32() ?? 0
                jsError = "Line \(line): \(exc.toString() ?? "unknown")"
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return Result(output: "", logs: bridge.logs, error: "Timed out after \(timeout)s.")
        }
        let output = jsResult?.toString() ?? "undefined"
        return Result(output: output, logs: bridge.logs, error: jsError)
    }

    // MARK: Built-in JS libraries

    /// Minimal dayjs-like date helpers. ~1.2KB
    private static let dayjsCore = """
        var dayjs = function(d) {
            var dt = d ? new Date(d) : new Date();
            return {
                format: function(f) {
                    var y = dt.getFullYear(), M = String(dt.getMonth()+1).padStart(2,'0'),
                        D = String(dt.getDate()).padStart(2,'0'),
                        h = String(dt.getHours()).padStart(2,'0'),
                        m = String(dt.getMinutes()).padStart(2,'0'),
                        s = String(dt.getSeconds()).padStart(2,'0');
                    return f.replace('YYYY',y).replace('MM',M).replace('DD',D)
                            .replace('HH',h).replace('mm',m).replace('ss',s);
                },
                add: function(n, unit) {
                    var nd = new Date(dt);
                    if (unit==='day') nd.setDate(nd.getDate()+n);
                    if (unit==='month') nd.setMonth(nd.getMonth()+n);
                    if (unit==='year') nd.setFullYear(nd.getFullYear()+n);
                    if (unit==='hour') nd.setHours(nd.getHours()+n);
                    return dayjs(nd);
                },
                diff: function(other, unit) {
                    var diff = dt - new Date(other);
                    if (unit==='day') return Math.round(diff/86400000);
                    if (unit==='hour') return Math.round(diff/3600000);
                    return diff;
                },
                isBefore: function(other) { return dt < new Date(other); },
                isAfter: function(other) { return dt > new Date(other); },
                toDate: function() { return dt; },
                valueOf: function() { return dt.getTime(); }
            };
        };
        """

    /// Simple statistics: mean, median, stddev, percentile, correlation, linearRegression. ~1.8KB
    private static let simpleStats = """
        var stats = {
            sum: function(arr) { return arr.reduce(function(a,b){return a+b;},0); },
            mean: function(arr) { return stats.sum(arr)/arr.length; },
            median: function(arr) {
                var s = arr.slice().sort(function(a,b){return a-b;});
                var m = Math.floor(s.length/2);
                return s.length%2 ? s[m] : (s[m-1]+s[m])/2;
            },
            min: function(arr) { return Math.min.apply(null, arr); },
            max: function(arr) { return Math.max.apply(null, arr); },
            stddev: function(arr) {
                var m = stats.mean(arr);
                return Math.sqrt(arr.reduce(function(a,b){return a+Math.pow(b-m,2);},0)/arr.length);
            },
            percentile: function(arr, p) {
                var s = arr.slice().sort(function(a,b){return a-b;});
                return s[Math.ceil(p/100*s.length)-1];
            },
            correlation: function(x, y) {
                var mx=stats.mean(x), my=stats.mean(y);
                var num=0, dx=0, dy=0;
                for (var i=0;i<x.length;i++){ num+=(x[i]-mx)*(y[i]-my); dx+=Math.pow(x[i]-mx,2); dy+=Math.pow(y[i]-my,2); }
                return num/Math.sqrt(dx*dy);
            },
            linearRegression: function(x, y) {
                var mx=stats.mean(x), my=stats.mean(y);
                var num=0, den=0;
                for (var i=0;i<x.length;i++){ num+=(x[i]-mx)*(y[i]-my); den+=Math.pow(x[i]-mx,2); }
                var slope = num/den;
                return { slope: slope, intercept: my-slope*mx, predict: function(v){ return slope*v+(my-slope*mx); } };
            },
            histogram: function(arr, bins) {
                var mn=stats.min(arr), mx=stats.max(arr), width=(mx-mn)/bins, buckets=[];
                for (var i=0;i<bins;i++){ var lo=mn+i*width, hi=lo+width;
                    buckets.push({min:lo, max:hi, count:arr.filter(function(v){return v>=lo&&(i===bins-1?v<=hi:v<hi);}).length}); }
                return buckets;
            }
        };
        """

    /// Wawa helpers: DataFrame-like operations + convenience functions. ~2.8KB
    private static let wawaHelpers = """
        var wawa = {
            // DataFrame-like: array of objects → query, transform, aggregate
            df: function(rows) {
                var r = rows || [];
                return {
                    rows: function() { return r; },
                    count: function() { return r.length; },
                    columns: function() { return r.length>0?Object.keys(r[0]):[]; },
                    filter: function(fn) { return wawa.df(r.filter(fn)); },
                    sort: function(col, desc) {
                        return wawa.df(r.slice().sort(function(a,b){
                            var va=a[col], vb=b[col];
                            return (va<vb?-1:va>vb?1:0)*(desc?-1:1);
                        }));
                    },
                    select: function(cols) {
                        return wawa.df(r.map(function(row){
                            var o={}; cols.forEach(function(c){o[c]=row[c];}); return o;
                        }));
                    },
                    head: function(n) { return wawa.df(r.slice(0,n||5)); },
                    tail: function(n) { return wawa.df(r.slice(-(n||5))); },
                    groupBy: function(col) {
                        var groups={};
                        r.forEach(function(row){ var k=row[col]; if(!groups[k])groups[k]=[]; groups[k].push(row); });
                        var result=[]; Object.keys(groups).forEach(function(k){ result.push({_key:k,_count:groups[k].length,_rows:groups[k]}); });
                        return wawa.df(result);
                    },
                    agg: function(col, fn) {
                        var groups={};
                        r.forEach(function(row){ var k=row._key||'all'; if(!groups[k])groups[k]=[]; groups[k].push(row); });
                        var result=[];
                        Object.keys(groups).forEach(function(k){
                            var vals=groups[k].map(function(rr){ return rr[col]; });
                            result.push({_key:k, _value:fn(vals)});
                        });
                        return wawa.df(result);
                    },
                    toJSON: function() { return JSON.stringify(r); },
                    toArray: function(col) { return r.map(function(row){return row[col];}); }
                };
            },

            // Convenience functions over native.*
            topRisky: function(limit) {
                var items = native.getAllItems();
                var scored = [];
                for (var i=0;i<items.length;i++) {
                    var a = native.getItemAnalysis(items[i].id);
                    if (!a || !a.risks || a.risks.length===0) continue;
                    scored.push({ title: items[i].title, id: items[i].id, riskCount: a.risks.length, risks: a.risks });
                }
                scored.sort(function(a,b){ return b.riskCount-a.riskCount; });
                return scored.slice(0, limit||10);
            },

            recentItems: function(days) {
                var cutoff = dayjs().add(-(days||7), 'day').toDate();
                return native.getAllItems().filter(function(i){ return new Date(i.createdAt) > cutoff; });
            },

            groupByType: function() {
                var items = native.getAllItems();
                var types = {};
                items.forEach(function(i){ var t=i.type; if(!types[t])types[t]=[]; types[t].push(i); });
                return Object.keys(types).map(function(k){ return { type: k, count: types[k].length }; });
            },

            pendingActions: function() {
                var all = native.getAllItems();
                var pending = [];
                for (var i=0;i<all.length;i++) {
                    var a = native.getItemAnalysis(all[i].id);
                    if (!a || !a.actionItems) continue;
                    for (var j=0;j<a.actionItems.length;j++) {
                        pending.push({ item: all[i].title, itemId: all[i].id, task: a.actionItems[j].task, owner: a.actionItems[j].owner });
                    }
                }
                return pending;
            },

            describe: function(arr) {
                if (arr.length===0) return {count:0};
                var nums = arr.filter(function(v){ return typeof v === 'number'; });
                return {
                    count: arr.length,
                    numericCount: nums.length,
                    min: nums.length>0?stats.min(nums):null,
                    max: nums.length>0?stats.max(nums):null,
                    mean: nums.length>0?stats.mean(nums):null,
                    median: nums.length>0?stats.median(nums):null,
                    stddev: nums.length>0?stats.stddev(nums):null
                };
            }
        };
        """
}

// MARK: - FieldAuthorityService

/// Centralized authority check for all field writes.
/// Implements the rule: user-owned > stabilized ontology > new LLM output
@MainActor
final class FieldAuthorityService {
    static let shared = FieldAuthorityService()
    private init() {}

    /// Returns true if the caller can modify the given field on the given model.
    func canModify(field: String, of model: any FieldProvidence, by origin: FieldOrigin) -> Bool {
        if origin == .user { return true }
        if origin == .system { return true }
        return !model.provenance.isUserOwned(field: field)
    }

    func markUserEdited(field: String, on model: some FieldProvidence) {
        var m = model
        m.provenance.mark(field: field, origin: .user)
        m.writeProvenance()
    }

    func markLLMEdited(field: String, on model: some FieldProvidence) {
        var m = model
        m.provenance.mark(field: field, origin: .llm)
        m.writeProvenance()
    }

    func markImportEdited(field: String, on model: some FieldProvidence) {
        var m = model
        m.provenance.mark(field: field, origin: .`import`)
        m.writeProvenance()
    }

    func firstBlockedField(attemptedFields: [String], model: any FieldProvidence, by origin: FieldOrigin) -> String? {
        attemptedFields.first { !canModify(field: $0, of: model, by: origin) }
    }

    func isUserCreated(_ task: TaskItem) -> Bool {
        task.createdBy == .user
    }

    func isLLMCreated(_ task: TaskItem) -> Bool {
        task.createdBy == .llm
    }
}

// MARK: - SignalPriorityService

/// Computes contextual priority for signals. Score is 0-100, dynamic, not a fixed enum.
/// Factors: impact, urgency, relevance, signal age, project state, ontology inertia.
@MainActor
final class SignalPriorityService {
    static let shared = SignalPriorityService()
    private init() {}

    func computePriority(
        signal: AgentSuggestion,
        project: Project?,
        activeItemCount: Int = 0,
        userContext: UserActivityContext = .idle
    ) -> Double {
        let impact = signal.impactScore ?? 0.5
        let urgency = signal.urgencyScore ?? 0.5
        let relevance = signal.relevanceScore ?? 0.5

        // Boost urgency for risk/alert types
        let typeBoost: Double = {
            switch signal.type {
            case "risk", "alert": return 1.2
            case "contradiction", "emerging_problem": return 1.1
            case "opportunity", "new_project": return 0.9
            default: return 1.0
            }
        }()

        // Project health modifier: struggling projects amplify signal priority
        let healthModifier: Double = {
            guard let health = project?.healthStatus else { return 1.0 }
            switch health {
            case "atRisk": return 1.25
            case "stale": return 1.1
            case "dormant": return 0.9
            default: return 1.0
            }
        }()

        // Age decay: signals older than 3 days start losing priority
        let ageDays = Date().timeIntervalSince(signal.createdAt) / 86400
        let ageDecay: Double = {
            if ageDays < 1 { return 1.0 }
            if ageDays < 3 { return 0.95 }
            if ageDays < 7 { return 0.85 }
            if ageDays < 14 { return 0.7 }
            return 0.5
        }()

        // User context modifier: what user is looking at matters
        let contextModifier: Double = {
            switch userContext {
            case .viewingProject: return 1.15
            case .viewingItem: return 1.05
            case .capturing: return 0.8
            default: return 1.0
            }
        }()

        // Ontology inertia: more items = more weight behind existing structure
        let inertiaModifier: Double = {
            if activeItemCount < 3 { return 1.0 }
            if activeItemCount < 10 { return 0.95 }
            return 0.85  // large projects resist change signals more
        }()

        let base = impact * 0.35 + urgency * 0.30 + relevance * 0.20 + 0.15
        let raw = base * typeBoost * healthModifier * ageDecay * contextModifier * inertiaModifier * 100
        return min(max(raw, 1.0), 100.0)
    }
}

/// What the user is currently doing — affects signal relevance.
enum UserActivityContext: String, Sendable {
    case idle
    case viewingProject
    case viewingItem
    case capturing
    case chatting
}

// MARK: - SignalResolutionService

/// Manages signal lifecycle transitions with audit trail.
@MainActor
final class SignalResolutionService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func markSeen(_ signal: AgentSuggestion) {
        guard signal.status == "visible" else { return }
        signal.status = "seen"
        try? context.save()
    }

    func markAcknowledged(_ signal: AgentSuggestion) {
        guard ["visible", "seen"].contains(signal.status) else { return }
        signal.status = "acknowledged"
        try? context.save()
    }

    func approve(_ signal: AgentSuggestion) {
        signal.status = "approved"
        signal.resolvedAt = Date()
        signal.resolvedByRaw = "user"
        try? context.save()
    }

    func reject(_ signal: AgentSuggestion, reason: String? = nil) {
        signal.status = "rejected"
        signal.resolvedAt = Date()
        signal.resolvedByRaw = "user"
        signal.resolutionReason = reason
        try? context.save()
        AgentMemoryStore.shared.write(
            pattern: "rejected_\(signal.type)",
            strategy: "User rejected: \(signal.title.prefix(60))",
            itemType: signal.type, contentType: nil, language: nil)
    }

    func archive(_ signal: AgentSuggestion, reason: String) {
        signal.status = "archived"
        signal.resolvedAt = Date()
        signal.resolvedByRaw = "user"
        signal.resolutionReason = reason
        try? context.save()
    }

    func autoArchive(_ signal: AgentSuggestion, reason: String) {
        signal.status = "auto_archived"
        signal.resolvedAt = Date()
        signal.resolvedByRaw = "system"
        signal.resolutionReason = reason
        try? context.save()
    }

    func transformToTask(_ signal: AgentSuggestion, projectID: UUID? = nil) -> TaskItem? {
        let taskSvc = TaskService(context: context)
        guard
            let task = try? taskSvc.create(
                title: signal.title,
                projectID: projectID ?? signal.projectID,
                priority: .medium,
                sourceItemID: signal.sourceItemID,
                createdBy: .user
            )
        else { return nil }
        signal.status = "transformed"
        signal.resolvedAt = Date()
        signal.resolvedByRaw = "user"
        signal.resolutionReason = "Transformed into task: \(task.id.uuidString)"
        try? context.save()
        return task
    }

    func transformToProject(_ signal: AgentSuggestion) -> Project? {
        let svc = ProjectService(context: context)
        guard let project = try? svc.create(name: signal.title) else { return nil }
        project.nameIsAutoGenerated = false
        var prov = project.provenance
        prov.mark(field: "name", origin: .user)
        project.fieldProvenanceJSON = prov.encode()
        signal.status = "transformed"
        signal.resolvedAt = Date()
        signal.resolvedByRaw = "user"
        signal.resolutionReason = "Transformed into project: \(project.id.uuidString)"
        try? context.save()
        return project
    }

    func ignore(_ signal: AgentSuggestion, reason: String) {
        signal.status = "ignored"
        signal.resolvedAt = Date()
        signal.resolvedByRaw = "user"
        signal.resolutionReason = reason
        try? context.save()
    }

    /// Auto-archive contradictions when new information resolves them.
    func resolveContradictions(relatedTo itemID: UUID, in projectID: UUID) {
        let all = (try? context.fetch(FetchDescriptor<AgentSuggestion>())) ?? []
        let contradictions = all.filter {
            $0.projectID == projectID
                && $0.type == "contradiction"
                && $0.isActive
        }
        for sig in contradictions {
            // If the new item is referenced in the signal's payload, auto-resolve
            if let json = sig.payloadJSON,
                let data = json.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let relatedIds = dict["related_item_ids"] as? [String],
                relatedIds.contains(itemID.uuidString)
            {
                autoArchive(sig, reason: "Resolved by new item: \(itemID.uuidString)")
            }
        }
    }
}

// MARK: - VersioningService

@MainActor
final class VersioningService {
    static let shared = VersioningService()
    private var changeCounts: [UUID: Int] = [:]
    private let autoMilestoneThreshold = 50
    private init() {}

    func recordChange(
        entityType: String, entityID: UUID, projectID: UUID? = nil,
        field: String, previousValue: String?, newValue: String?,
        origin: FieldOrigin, context: ModelContext
    ) {
        let record = ChangeRecord(
            entityType: entityType, entityID: entityID, projectID: projectID,
            field: field, previousValue: previousValue, newValue: newValue, origin: origin)
        context.insert(record)
        if let pid = projectID {
            let count = (changeCounts[pid] ?? 0) + 1
            changeCounts[pid] = count
            if count % autoMilestoneThreshold == 0 {
                createSnapshot(projectID: pid, trigger: .auto_milestone, context: context)
            }
        }
        try? context.save()
    }

    func createSnapshot(
        projectID: UUID, label: String? = nil,
        trigger: SnapshotTrigger = .manual, context: ModelContext
    ) {
        let allRecords = changes(for: projectID, context: context)
        let unassigned = allRecords.filter { $0.snapshotID == nil }
        let snapshot = ProjectSnapshot(
            projectID: projectID, label: label, trigger: trigger,
            changeCount: unassigned.count)
        context.insert(snapshot)
        for record in unassigned { record.snapshotID = snapshot.id }
        changeCounts[projectID] = 0
        try? context.save()
    }

    func changes(
        for projectID: UUID, since: Date? = nil, limit: Int = 100,
        context: ModelContext
    ) -> [ChangeRecord] {
        let all = (try? context.fetch(FetchDescriptor<ChangeRecord>())) ?? []
        return all.filter { r in
            r.projectID == projectID && (since == nil || r.timestamp >= since!)
        }.sorted(by: { $0.timestamp > $1.timestamp }).prefix(limit).map { $0 }
    }

    func snapshots(for projectID: UUID, context: ModelContext) -> [ProjectSnapshot] {
        let all = (try? context.fetch(FetchDescriptor<ProjectSnapshot>())) ?? []
        return all.filter { $0.projectID == projectID }.sorted(by: { $0.createdAt > $1.createdAt })
    }

    func diff(between older: ProjectSnapshot, and newer: ProjectSnapshot, context: ModelContext) -> [ChangeRecord] {
        let all = (try? context.fetch(FetchDescriptor<ChangeRecord>())) ?? []
        return all.filter { ($0.snapshotID == newer.id || $0.snapshotID == nil) && $0.timestamp > older.createdAt }
    }

    func restore(to snapshot: ProjectSnapshot, context: ModelContext) {
        let records = changes(for: snapshot.projectID, context: context)
        let snapshotRecords = records.filter { $0.timestamp <= snapshot.createdAt }
        var lastValues: [String: String?] = [:]
        for r in snapshotRecords.sorted(by: { $0.timestamp < $1.timestamp }) {
            lastValues["\(r.entityType):\(r.entityID.uuidString):\(r.field)"] = r.newValue ?? r.previousValue
        }
        for (key, value) in lastValues {
            let parts = key.split(separator: ":")
            guard parts.count == 3, let eid = UUID(uuidString: String(parts[1])), let val = value else { continue }
            applyRestore(
                entityType: String(parts[0]), entityID: eid, field: String(parts[2]),
                value: val, projectID: snapshot.projectID, context: context)
        }
    }

    private func applyRestore(
        entityType: String, entityID: UUID, field: String,
        value: String, projectID: UUID, context: ModelContext
    ) {
        switch entityType {
        case "TaskItem":
            guard let task = try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == entityID })).first else { return }
            switch field {
            case "title": task.title = value
            case "status": if let s = TaskStatus(rawValue: value) { task.status = s }
            case "priority": if let p = TaskPriority(rawValue: value) { task.priority = p }
            case "ownerName": task.ownerName = value.isEmpty ? nil : value
            default: break
            }
        case "Project":
            guard let project = try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == entityID })).first else { return }
            switch field {
            case "name": project.name = value
            case "summary": project.summary = value.isEmpty ? nil : value
            case "customInstructions": project.customInstructions = value.isEmpty ? nil : value
            default: break
            }
        case "KnowledgeItem":
            guard let item = try? context.fetch(FetchDescriptor<KnowledgeItem>(predicate: #Predicate { $0.id == entityID })).first else { return }
            switch field {
            case "title": item.title = value
            case "bodyText": item.bodyText = value.isEmpty ? nil : value
            default: break
            }
        default: break
        }
        try? context.save()
        recordChange(
            entityType: entityType, entityID: entityID, projectID: projectID,
            field: field, previousValue: nil, newValue: value, origin: .system, context: context)
    }
}

// MARK: - QueuePriorityService

/// Computes processing queue priority (0-100). User actions always beat background processing.
@MainActor
final class QueuePriorityService {
    static let shared = QueuePriorityService()
    private init() {}

    /// Compute priority for a queue entry based on context.
    func computePriority(
        itemID: UUID,
        projectID: UUID?,
        trigger: QueueTrigger,
        hasActiveProject: Bool = false,
        itemAge: TimeInterval? = nil
    ) -> Int {
        var score = 0

        // Trigger base (40 pts) — user action > system
        switch trigger {
        case .directUserAction: score += 40  // "Transcribe", "Re-analyze"
        case .newCapture: score += 30  // Recording just finished
        case .projectAssignment: score += 25  // Swipe to project
        case .batchReprocess: score += 10  // "Re-process All"
        case .backgroundBackfill: score += 5  // Embedding backfill
        }

        // Recency (25 pts) — newer items first
        if let age = itemAge {
            if age < 300 {
                score += 25
            }  // < 5 min
            else if age < 3600 {
                score += 20
            }  // < 1 hour
            else if age < 86400 {
                score += 12
            }  // < 1 day
            else {
                score += 5
            }
        } else {
            score += 15  // Unknown age = middle
        }

        // Project context (20 pts) — active/open project has priority
        if hasActiveProject {
            score += 20
        } else if projectID != nil {
            score += 10
        }

        // Retry boost (5 pts) — retries aren't penalized but don't jump the queue
        // Applied by caller when retryCount > 0

        return min(score + 10, 100)  // +10 floor so nothing is zero-priority
    }
}

/// What triggered this queue entry.
enum QueueTrigger: String, Sendable {
    case directUserAction  // User tapped a specific button
    case newCapture  // Recording/scan/photo just completed
    case projectAssignment  // Item assigned to project via swipe
    case batchReprocess  // Batch "Re-process All"
    case backgroundBackfill  // Embedding or other background work
}

// MARK: - ProcessingQueueService

/// Manages the visible processing queue with throttling, priority, and cancellation.
@MainActor
final class ProcessingQueueService: ObservableObject {
    @Published var entries: [QueueEntry] = []
    @Published var isPaused: Bool = false
    @Published var activeJobCount: Int = 0

    let maxConcurrentJobs = 2

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskCount = 0
    private var pipeline: ContentPipelineService?

    func setPipeline(_ pipeline: ContentPipelineService) {
        self.pipeline = pipeline
    }

    // MARK: - Enqueue

    func enqueue(
        itemID: UUID,
        projectID: UUID? = nil,
        trigger: QueueTrigger = .newCapture,
        priority: Int? = nil
    ) -> QueueEntry {
        AppLog.event(
            "pipeline", "Enqueue item — itemID=\(itemID.uuidString.prefix(8)) trigger=\(trigger) projectID=\(projectID?.uuidString.prefix(8) ?? "nil")")
        // Deduplicate: if item already queued/processing, skip
        if let existing = entries.first(where: { $0.itemID == itemID && ($0.status == .queued || $0.status == .processing) }) {
            AppLog.debug("pipeline", "Item already queued — skipping duplicate")
            return existing
        }

        let computedPriority =
            priority
            ?? QueuePriorityService.shared.computePriority(
                itemID: itemID, projectID: projectID, trigger: trigger)
        let entry = QueueEntry(
            itemID: itemID, projectID: projectID, status: .queued,
            priority: computedPriority)
        entries.append(entry)
        sortEntries()
        processNext()
        return entry
    }

    // MARK: - Queue management

    func cancel(_ entryID: UUID) {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        if entry.status == .processing {
            activeTasks[entryID]?.cancel()
            activeTasks[entryID] = nil
            activeJobCount = max(0, activeJobCount - 1)
            endBackgroundTask()
        }
        entry.status = .cancelled
        entry.completedAt = Date()
        entries.removeAll { $0.id == entryID }
        processNext()
    }

    func pauseQueue() {
        isPaused = true
    }

    func resumeQueue() {
        isPaused = false
        processNext()
    }

    func remove(_ entryID: UUID) {
        cancel(entryID)
    }

    /// Re-enqueue a failed item (e.g., after connectivity restored).
    func retry(_ entryID: UUID) {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        entry.status = .queued
        entry.completedAt = nil
        sortEntries()
        processNext()
    }

    // MARK: - Processing

    private func processNext() {
        guard !isPaused, activeJobCount < maxConcurrentJobs else { return }

        let pending =
            entries
            .filter { $0.status == .queued }
            .sorted { $0.priority > $1.priority || ($0.priority == $1.priority && $0.queuedAt < $1.queuedAt) }

        guard let next = pending.first else { return }

        // Safety: if pipeline was never injected via setPipeline(), mark all queued
        // items as failed rather than leaving them stuck in "queued" state forever.
        guard let pipeline = self.pipeline else {
            AppLog.error("pipeline", "Pipeline not set — aborting queue. \(pending.count) items will be marked failed.")
            for entry in pending where entry.status == .queued {
                entry.status = .failed
                entry.completedAt = Date()
            }
            entries.removeAll { $0.status == .failed && Date().timeIntervalSince($0.completedAt ?? Date()) > 60 }
            return
        }

        AppLog.event(
            "pipeline",
            "Processing item — itemID=\(next.itemID.uuidString.prefix(8)) priority=\(next.priority) projectID=\(next.projectID?.uuidString.prefix(8) ?? "nil")")

        next.status = .processing
        next.startedAt = Date()
        activeJobCount += 1
        beginBackgroundTask()

        let entryID = next.id
        let itemID = next.itemID
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                await pipeline.processEntry(
                    itemID: itemID,
                    projectID: next.projectID
                )
                await MainActor.run { [weak self] in
                    self?.finishJob(entryID, failed: false, error: nil)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishJob(entryID, failed: true, error: error.localizedDescription)
                }
            }
        }
        activeTasks[entryID] = task
    }

    private func finishJob(_ entryID: UUID, failed: Bool = false, error: String? = nil) {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        if entry.status == .cancelled {
            AppLog.warn("pipeline", "Processing cancelled — itemID=\(entry.itemID.uuidString.prefix(8))")
        } else if failed {
            entry.retryCount += 1
            if entry.retryCount < entry.maxRetries {
                // Re-queue for retry with exponential backoff.
                // Immediate retry on rate-limited API is doomed — wait
                // 5s, 15s, 45s between attempts.
                entry.status = .queued
                entry.lastError = error
                let backoffSeconds = Int(pow(3.0, Double(entry.retryCount))) * 5  // 5, 15, 45
                AppLog.warn(
                    "pipeline",
                    "Processing failed (attempt \(entry.retryCount)/\(entry.maxRetries)) — itemID=\(entry.itemID.uuidString.prefix(8)) retry in \(backoffSeconds)s error=\(error ?? "unknown")"
                )
                activeTasks[entryID] = nil
                activeJobCount = max(0, activeJobCount - 1)
                endBackgroundTask()
                sortEntries()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds) * 1_000_000_000)
                    guard entries.contains(where: { $0.id == entryID && $0.status == .queued }) else { return }
                    processNext()
                }
                return
            }
            entry.status = .failed
            entry.completedAt = Date()
            entry.lastError = error
            AppLog.error("pipeline", "Processing permanently failed after \(entry.retryCount) retries — itemID=\(entry.itemID.uuidString.prefix(8))")
        } else {
            entry.status = .done
            entry.completedAt = Date()
            AppLog.event("pipeline", "Processing complete — itemID=\(entry.itemID.uuidString.prefix(8))")
        }
        activeTasks[entryID] = nil
        activeJobCount = max(0, activeJobCount - 1)
        endBackgroundTask()
        sortEntries()
        processNext()
    }

    private func sortEntries() {
        entries.sort { $0.priority > $1.priority || ($0.priority == $1.priority && $0.queuedAt < $1.queuedAt) }
        for (idx, entry) in entries.enumerated() {
            entry.position = idx
        }
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        backgroundTaskCount += 1
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WawaQueue") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundTask()
            }
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

// MARK: - Connectivity Monitor

/// Monitors network connectivity and notifies when the device goes online.
/// Used to auto-retry transcription jobs queued while offline.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    static let shared = ConnectivityMonitor()

    @Published private(set) var isOnline: Bool = true
    @Published private(set) var isExpensive: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wawa-note.connectivity")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                self.isExpensive = expensive
                if wasOffline && online {
                    AppLog.event("network", "Connectivity restored — retrying queued jobs")
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

// MARK: - OntologyInertiaService

@MainActor
final class OntologyInertiaService {
    static let shared = OntologyInertiaService()
    private init() {}

    func computeInertia(projectID: UUID, context: ModelContext) -> Double {
        let items = (try? ProjectService(context: context).items(in: projectID)) ?? []
        let edgeSvc = GraphEdgeService(context: context)
        let edges = (try? edgeSvc.recentEdges(limit: 1000)) ?? []
        let itemIDs = Set(items.map(\.id))
        let projectEdges = edges.filter { itemIDs.contains($0.fromID) || itemIDs.contains($0.toID) }
        let contradictionCount = projectEdges.filter { $0.edgeType == .contradicts }.count
        let oldestAge = items.map { Date().timeIntervalSince($0.createdAt) }.max() ?? 0
        let edgeDensity = items.count > 1 ? Double(projectEdges.count) / Double(items.count * (items.count - 1)) : 0
        let itemFactor = min(Double(items.count) / 20.0, 1.0)
        let ageFactor = min(oldestAge / (90 * 86400), 1.0)
        let densityFactor = min(edgeDensity / 0.15, 1.0)
        let contradictionPenalty = min(Double(contradictionCount) * 0.1, 0.3)
        return min((itemFactor * 0.35 + ageFactor * 0.25 + densityFactor * 0.4) - contradictionPenalty, 1.0)
    }

    var inertiaLabel: (Double) -> String {
        { score in score >= 0.7 ? "Established" : score >= 0.4 ? "Stabilizing" : "Forming" }
    }
}

// MARK: - PresetExportService

@MainActor
final class PresetExportService {
    static let shared = PresetExportService()
    private init() {}

    func exportPreset(from project: Project) -> Preset {
        var rules: [String] = []
        if project.customInstructions?.isEmpty == false { rules.append("custom_instructions_present") }
        return Preset(
            id: "preset/\(project.slug)", name: project.name,
            description: "Preset exported from project \"\(project.name)\"",
            lensID: project.frameworkId, frameworkJSON: project.frameworkJSON,
            customInstructions: project.customInstructions, analysisRules: rules,
            version: 1)
    }

    func applyPreset(_ preset: Preset, to project: Project) {
        project.frameworkId = preset.lensID
        project.frameworkJSON = preset.frameworkJSON
        if let instructions = preset.customInstructions {
            project.customInstructions = instructions
        }
    }

    func builtInPresets() -> [Preset] {
        LensCatalogService.shared.allLenses.map { lens in
            var fwJSON: String?
            if let fw = lens.framework { fwJSON = (try? JSONEncoder().encode(fw)).flatMap { String(data: $0, encoding: .utf8) } }
            return Preset(
                id: "preset/\(lens.id)", name: lens.name, description: lens.description,
                lensID: lens.id, frameworkJSON: fwJSON, version: 1)
        }
    }
}

// MARK: - Config Resolver

/// Resolves configuration files through a cascade:
/// 1. `projects/{slug}/config/{filename}` — project-level (highest priority)
/// 2. `configs/{filename}` — global user overrides
/// 3. `Resources/{filename}` — bundle defaults
enum ConfigResolver {
    static func resolve(_ filename: String, projectSlug: String? = nil) -> Data? {
        let store = FileArtifactStore()

        // 1. Project-level override
        if let slug = projectSlug {
            let projectURL = store.projectConfigDirectoryURL(for: slug).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: projectURL.path),
                let data = try? Data(contentsOf: projectURL)
            {
                AppLog.provider.info("ConfigResolver: using project-level \(filename) for \(slug)")
                return data
            }
        }

        // 2. Global user override
        let globalURL = store.configsDirectoryURL().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: globalURL.path),
            let data = try? Data(contentsOf: globalURL)
        {
            AppLog.provider.info("ConfigResolver: using global override \(filename)")
            return data
        }

        // 3. Bundle default (try multiple paths)
        let bundlePaths = [filename, "Pipelines/\(filename)", "Skills/\(filename)", "Schemas/\(filename)"]
        for path in bundlePaths {
            if let url = Bundle.main.url(forResource: path, withExtension: nil),
                let data = try? Data(contentsOf: url)
            {
                return data
            }
        }

        AppLog.provider.warning("ConfigResolver: \(filename) not found in any level")
        return nil
    }

    /// Resolves and decodes a Codable config file.
    static func resolve<T: Decodable>(_ filename: String, projectSlug: String? = nil, as type: T.Type) -> T? {
        guard let data = resolve(filename, projectSlug: projectSlug) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Pipeline Definition Model

struct PipeParams: Codable, Sendable {
    let maxIterations: Int?
    let retryAttempts: Int?
    let retryBackoffSeconds: [Int]?
    let agentMode: String?
    let extractionOnly: Bool?
}

struct PipeStage: Codable, Sendable {
    let id: String
    let description: String?
    let condition: String?
    let onFailure: String?
    let steps: [PipeStep]?
    let stages: [PipeStage]?
}

struct PipeStep: Codable, Sendable {
    let action: String
    let value: String?
    let prompt: String?
}

struct PipeDefinition: Codable, Sendable {
    let name: String
    let version: String
    let description: String?
    let params: PipeParams?
    let stages: [PipeStage]
}

// MARK: - Pipeline Store

@MainActor
final class PipelineStore: ObservableObject {
    static let shared = PipelineStore()
    @Published private(set) var definitions: [String: PipeDefinition] = [:]
    private(set) var activeName: String = "standard"

    private init() {
        loadBuiltIn()
        let url = FileArtifactStore().configsDirectoryURL().appendingPathComponent("pipeline.json")
        if FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let overrides = try? JSONDecoder().decode([String: PipeDefinition].self, from: data)
        {
            for (name, def) in overrides { self.definitions[name] = def }
        }
        AppLog.provider.info("PipelineStore: \(self.definitions.count) pipeline(s) loaded")
    }

    private func loadBuiltIn() {
        guard let url = Bundle.main.url(forResource: "Pipelines", withExtension: nil) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        for fileURL in files where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                let def = try? JSONDecoder().decode(PipeDefinition.self, from: data)
            else { continue }
            definitions[def.name] = def
        }
    }

    var active: PipeDefinition? { active() }

    /// Returns the pipeline definition for a given project context.
    /// Resolves through cascade: project/config → configs/ → bundle.
    func active(for projectSlug: String? = nil) -> PipeDefinition? {
        if let slug = projectSlug,
            let def = ConfigResolver.resolve("pipeline.json", projectSlug: slug, as: PipeDefinition.self)
        {
            return def
        }
        if let def = ConfigResolver.resolve("pipeline.json", as: PipeDefinition.self) {
            return def
        }
        return definitions[activeName]
    }

    func saveOverride(_ def: PipeDefinition, projectSlug: String? = nil) {
        let url: URL
        if let slug = projectSlug {
            url = FileArtifactStore().projectConfigDirectoryURL(for: slug).appendingPathComponent("pipeline.json")
        } else {
            url = FileArtifactStore().configsDirectoryURL().appendingPathComponent("pipeline.json")
        }
        var overrides: [String: PipeDefinition] = [:]
        if FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let existing = try? JSONDecoder().decode([String: PipeDefinition].self, from: data)
        {
            overrides = existing
        }
        overrides[def.name] = def
        if let data = try? JSONEncoder().encode(overrides) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileArtifactStore().atomicWriteWithBackup(data: data, url: url)
            definitions[def.name] = def
        }
    }
}
