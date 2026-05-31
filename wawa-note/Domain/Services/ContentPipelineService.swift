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
                _ = await extraction.analyze(text: effectiveText, item: item)
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
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WawaPipeline") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

// MARK: - Pipeline stage (for UI progress)

enum PipelineStage: String, Sendable {
    case extracting = "Extracting content..."
    case analyzing = "Analyzing..."
    case ingesting = "Updating project..."
}

