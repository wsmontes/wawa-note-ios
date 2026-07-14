import Foundation
import SwiftData
import WawaNoteCore

// Related JIRA: KAN-XX

/// Runs AI analysis on extracted content. Extracted from ContentPipelineService
/// as part of the unified pipeline refactoring.
@MainActor
final class ContentAnalysisService {
  private let fileStore: FileArtifactStore
  private let modelContainer: ModelContainer

  init(fileStore: FileArtifactStore = FileArtifactStore(), modelContainer: ModelContainer) {
    self.fileStore = fileStore
    self.modelContainer = modelContainer
  }

  /// Analyze extracted text for a KnowledgeItem.
  /// Sets item.status = .analyzed on success, .failed on error.
  /// - Returns: true if analysis completed successfully.
  func analyze(item: KnowledgeItem, context: ModelContext) async -> Bool {
    guard !Task.isCancelled else {
      item.lastErrorRaw = "Analysis was cancelled."
      item.status = .failed
      context.safeSave(context: "analysis-cancelled", itemId: item.id)
      return false
    }

    // Resolve provider
    guard let provider = try? ProviderRouter.resolveActive(context: context) else {
      item.lastErrorRaw =
        ExtractionError.engineError("No AI provider configured. Go to Settings → AI Services.")
        .errorDescription
      item.status = .failed
      context.safeSave(context: "analysis-no-provider", itemId: item.id)
      return false
    }

    // Get text to analyze
    let extractionSvc = ContentExtractionService(modelContext: context, fileStore: fileStore)
    guard let text = await extractionSvc.bestAvailableText(for: item),
      !text.trimmingCharacters(in: .whitespaces).isEmpty
    else {
      item.lastErrorRaw = "No extractable text found for analysis."
      item.status = .failed
      context.safeSave(context: "analysis-no-text", itemId: item.id)
      return false
    }

    // Build source context
    let sourceCtx = SourceContext.from(item)
    let settings = AutomationSettings.shared
    let model = settings.resolveAutoAnalysisModel(context: context) ?? settings.autoAnalysisModel

    // Chunk text for analysis
    let segments = extractionSvc.chunkText(text, itemID: item.id)
    let transcript = Transcript(
      meetingId: item.id, languageCode: nil, segments: segments, sourceEngineId: "text-direct"
    )

    // Retry loop (max 2 attempts)
    var lastError: String?
    for attempt in 0..<2 {
      if attempt > 0 {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }

      do {
        let result = try await AnalysisService().analyze(
          transcript: transcript, using: provider, model: model,
          meetingId: item.id, sourceContext: sourceCtx
        )

        try fileStore.createMeetingDirectory(for: item.id)
        try fileStore.writeArtifact(result, fileName: "analysis.json", meetingId: item.id)

        item.status = .analyzed
        item.analysisProviderId = model
        item.inboxDate = nil
        context.safeSave(context: "analysis-success", itemId: item.id)

        NotificationCenter.default.post(name: .analysisReady, object: item.id.uuidString)
        return true
      } catch let error as ProviderError where !error.isRetryable {
        lastError = error.localizedDescription
        break  // Permanent error — no retry
      } catch {
        lastError = error.localizedDescription
        // Transient error — will retry
      }
    }

    // All retries exhausted or permanent error
    item.status = .failed
    item.lastErrorRaw = lastError ?? "Analysis failed after retries."
    context.safeSave(context: "analysis-failed", itemId: item.id)
    return false
  }
}
