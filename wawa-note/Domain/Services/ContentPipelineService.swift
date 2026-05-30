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
@MainActor
final class ContentPipelineService {
    static let shared = ContentPipelineService()

    private var activeJobs: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    /// Process an item through the full pipeline: extract → analyze → ingest.
    func process(_ itemID: UUID, using modelContext: ModelContext) {
        guard activeJobs[itemID] == nil else { return }

        let settings = AutomationSettings.shared
        let extraction = ContentExtractionService(modelContext: modelContext)

        activeJobs[itemID] = Task { @MainActor in
            defer {
                activeJobs[itemID] = nil
                endBackgroundTask()
                NotificationCenter.default.post(name: .pipelineCompleted, object: itemID.uuidString)
            }
            beginBackgroundTask()

            guard var item = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) else { return }

            // ── Phase 1: Extract text ──────────────────────────
            let text: String?
            let isAudio = item.audioFileRelativePath != nil

            if isAudio && settings.autoTranscribe {
                text = await extraction.extractTextFromAudio(item)
                // Re-fetch to pick up transcription state
                if let updated = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID) {
                    item = updated
                }
            } else if !isAudio {
                text = await extraction.extractTextFromDocument(item)
            } else {
                text = nil
            }

            guard let text, !text.isEmpty else {
                AppLog.provider.warning("ContentPipeline: no text extracted for item \(itemID)")
                return
            }

            // ── Phase 2: Analyze ──────────────────────────────
            if settings.autoAnalyze && item.analysisProviderId == nil {
                NotificationCenter.default.post(name: .contentPipelineStageChanged, object: itemID.uuidString,
                                                userInfo: ["stage": PipelineStage.analyzing.rawValue])
                _ = await extraction.analyze(text: text, item: item)
            }

            // ── Phase 3: Project ingestion ─────────────────────
            if let updated = try? KnowledgeItemService(context: modelContext).fetchItem(id: itemID),
               let projectID = updated.projectID {
                NotificationCenter.default.post(name: .contentPipelineStageChanged, object: itemID.uuidString,
                                                userInfo: ["stage": PipelineStage.ingesting.rawValue])
                ProjectIngestionState.shared.start(projectID)
                await ProjectIngestionPipeline.shared.ingest(itemID: itemID, projectID: projectID, using: modelContext)
                ProjectIngestionState.shared.finish(projectID)
            }
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

extension Notification.Name {
    static let contentPipelineStageChanged = Notification.Name("ContentPipelineStageChanged")
}
