import Foundation
import SwiftData
import WawaNoteCore

// Related JIRA: KAN-538

// MARK: - Transcription Pipeline

/// Single orchestrator for all content extraction + analysis.
/// Every entry point routes through here via ProcessingQueue.
///
/// Guarantee: every call reaches a terminal state (.failed, .analyzed,
/// .pendingReview) or the defer block forces .failed.
@MainActor
final class TranscriptionPipeline {
  static let shared = TranscriptionPipeline()

  enum Mode {
    /// Extract text only, then set .pendingReview for user verification.
    case transcribeOnly
    /// Extract + analyze, set .analyzed on completion.
    case full
  }

  private var activeJobs: [UUID: Task<Void, Never>] = [:]
  private let fileStore = FileArtifactStore()
  private lazy var audioProcessor = AudioProcessor(fileStore: fileStore)
  private lazy var imageProcessor = ImageProcessor(fileStore: fileStore)
  private lazy var textProcessor = TextProcessor()

  private init() {}

  // MARK: - Public API

  /// Process an item through the pipeline.
  ///
  /// - Parameters:
  ///   - itemID: The UUID of the KnowledgeItem to process.
  ///   - context: A SwiftData ModelContext for persistence.
  ///   - mode: `.full` (extract + analyze) or `.transcribeOnly` (extract only).
  ///
  /// Dedup: if the item is already being processed, the call is silently ignored.
  /// Terminal state guarantee: every exit path leaves the item in .failed,
  /// .analyzed, or .pendingReview. If none is reached, the defer block forces .failed.
  func run(
    itemID: UUID,
    context: ModelContext,
    mode: Mode = .full
  ) async {
    if let activeJob = activeJobs[itemID] {
      AppLog.provider.info("TranscriptionPipeline: item \(itemID) already active, awaiting it")
      await activeJob.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      var terminalStateReached = false
      defer {
        self.activeJobs[itemID] = nil
        if !terminalStateReached {
          // Fetch with flat optional to handle throws → nil → unwrap in one step.
          if let stuckItem = (try? KnowledgeItemService(context: context).fetchItem(id: itemID))
            ?? nil,
            !stuckItem.status.isTerminal
          {
            stuckItem.lastErrorRaw = "Pipeline terminated without reaching a terminal state."
            stuckItem.status = .failed
            context.safeSave(context: "pipeline-terminal-guarantee", itemId: itemID)
          }
        }
        NotificationCenter.default.post(name: .pipelineCompleted, object: itemID.uuidString)
      }

      guard !Task.isCancelled else {
        terminalStateReached = true
        return
      }

      // Fetch item (handle double-optional from throws → KnowledgeItem?)
      guard let item = (try? KnowledgeItemService(context: context).fetchItem(id: itemID)) ?? nil
      else {
        AppLog.provider.error("TranscriptionPipeline: item \(itemID) not found, aborting")
        terminalStateReached = true
        return
      }

      // Phase 0: Extract
      item.status = .transcribing
      context.safeSave(context: "pipeline-start-extraction", itemId: itemID)
      NotificationCenter.default.post(
        name: .contentPipelineStageChanged, object: itemID.uuidString,
        userInfo: ["stage": "transcribing"]
      )

      let processor = resolveProcessor(for: item.type)
      guard let extractedText = await processor.extract(from: item, context: context) else {
        // Processor already set .failed + lastErrorRaw on failure
        AppLog.provider.error("TranscriptionPipeline: extraction failed for item \(itemID)")
        terminalStateReached = true
        return
      }

      AppLog.provider.info(
        "TranscriptionPipeline: extraction complete for item \(itemID) — \(extractedText.count) chars"
      )

      // Phase 1: Analyze
      if mode == .full {
        item.status = .analyzing
        context.safeSave(context: "pipeline-start-analysis", itemId: itemID)
        NotificationCenter.default.post(
          name: .contentPipelineStageChanged, object: itemID.uuidString,
          userInfo: ["stage": "analyzing"]
        )

        let extractionSvc = ContentExtractionService(
          modelContext: context, fileStore: fileStore
        )

        do {
          let success = try await extractionSvc.analyze(text: extractedText, item: item)
          if success {
            // ContentExtractionService.analyze already set .analyzed + saved
            AppLog.provider.info(
              "TranscriptionPipeline: analysis complete for item \(itemID)"
            )
          } else {
            // analyze returned false (empty text or no provider configured)
            if item.status != .failed {
              item.status = .failed
              item.lastErrorRaw = "Analysis failed: no provider or empty text."
              context.safeSave(context: "pipeline-analysis-failed", itemId: itemID)
            }
          }
        } catch {
          AppLog.provider.error(
            "TranscriptionPipeline: analysis error for item \(itemID): \(error.localizedDescription)"
          )
          if item.status != .failed {
            item.status = .failed
            item.lastErrorRaw = "Analysis failed: \(error.localizedDescription)"
            context.safeSave(context: "pipeline-analysis-error", itemId: itemID)
          }
        }

        terminalStateReached = true
      } else {
        // transcribeOnly: set pendingReview so user can verify extraction
        item.status = .pendingReview
        context.safeSave(context: "pipeline-extraction-complete", itemId: itemID)
        terminalStateReached = true
      }
    }
    activeJobs[itemID] = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Cancel a running pipeline job for the given item.
  func cancel(_ itemID: UUID) {
    activeJobs[itemID]?.cancel()
    activeJobs[itemID] = nil
  }

  /// Returns true if the item is currently being processed.
  func isProcessing(_ itemID: UUID) -> Bool {
    activeJobs[itemID] != nil
  }

  /// The number of currently active pipeline jobs.
  var activeJobCount: Int { activeJobs.count }

  // MARK: - Private

  private func resolveProcessor(for type: KnowledgeItemType) -> any ContentProcessor {
    switch type {
    case .audio: return audioProcessor
    case .image: return imageProcessor
    default: return textProcessor
    }
  }
}
