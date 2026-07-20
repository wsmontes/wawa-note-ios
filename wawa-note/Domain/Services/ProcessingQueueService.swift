import Foundation
import SwiftData
import UIKit
import WawaNoteCore

// MARK: - Processing Queue Service

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

  /// Maximum completed/failed entries to keep before auto-pruning.
  private let maxRetainedEntries = 50

  func setPipeline(_ pipeline: ContentPipelineService) {
    self.pipeline = pipeline
    registerMemoryPressure()
  }

  // MARK: - Memory Pressure

  private func registerMemoryPressure() {
    MemoryPressureHandler.shared.register("ProcessingQueue: pause + prune") { [weak self] in
      guard let self else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Under memory pressure: pause queue, cancel non-active jobs, prune history
        if !self.isPaused {
          self.isPaused = true
          AppLog.warn("pipeline", "Memory pressure — pausing queue and pruning entries")
        }
        self.autoPrune()
      }
    }
  }

  // MARK: - Enqueue

  func enqueue(
    itemID: UUID,
    projectID: UUID? = nil,
    trigger: QueueTrigger = .newCapture,
    priority: Int? = nil,
    maxRetries: Int? = nil
  ) -> QueueEntry {
    AppLog.event(
      "pipeline",
      "Enqueue item — itemID=\(itemID.uuidString.prefix(8)) trigger=\(trigger) projectID=\(projectID?.uuidString.prefix(8) ?? "nil")"
    )
    // Deduplicate: if item already queued/processing, skip
    if let existing = entries.first(where: {
      $0.itemID == itemID && ($0.status == .queued || $0.status == .processing)
    }) {
      AppLog.debug("pipeline", "Item already queued — skipping duplicate")
      return existing
    }

    let computedPriority =
      priority
      ?? QueuePriorityService.shared.computePriority(
        itemID: itemID, projectID: projectID, trigger: trigger)
    // Long audio (30min+) needs more retries — each retry resumes from
    // checkpoint so forward progress is preserved.
    let effectiveMaxRetries = maxRetries ?? 2
    let entry = QueueEntry(
      itemID: itemID, projectID: projectID, status: .queued,
      priority: computedPriority, maxRetries: effectiveMaxRetries)
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
    // Notify observers so the detail view can reset its processing state.
    NotificationCenter.default.post(name: .pipelineCompleted, object: entry.itemID.uuidString)
    entries.removeAll { $0.id == entryID }
    processNext()
  }

  func pauseQueue() {
    isPaused = true
    // Cancel all active tasks and re-queue them so Resume picks them up.
    for (entryID, task) in activeTasks {
      task.cancel()
      activeTasks[entryID] = nil
      if let entry = entries.first(where: { $0.id == entryID }), entry.status == .processing {
        entry.status = .queued
        entry.startedAt = nil
      }
    }
    activeJobCount = 0
    endBackgroundTask()
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

  /// Cancels all queued and processing items. Removes them from the queue.
  func cancelAll() {
    for (_, task) in activeTasks { task.cancel() }
    activeTasks.removeAll()
    activeJobCount = 0
    endBackgroundTask()
    entries.removeAll { $0.status == .queued || $0.status == .processing }
  }

  /// Removes all done, failed, and cancelled entries from the queue.
  func clearCompleted() {
    entries.removeAll { $0.status == .done || $0.status == .failed || $0.status == .cancelled }
  }

  /// Removes all failed entries from the queue, keeping completed ones.
  func clearFailed() {
    entries.removeAll { $0.status == .failed }
  }

  /// Auto-prune: removes terminal entries (done/failed/cancelled) when the
  /// total count exceeds `maxRetainedEntries`. Keeps the most recent ones.
  /// Called automatically after each job finishes and on memory pressure.
  private func autoPrune() {
    let terminal = entries.filter {
      $0.status == .done || $0.status == .failed || $0.status == .cancelled
    }
    guard terminal.count > maxRetainedEntries else { return }
    // Sort by completion date, remove oldest
    let sorted = terminal.sorted {
      ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast)
    }
    let toRemove = Set(sorted.prefix(terminal.count - maxRetainedEntries).map(\.id))
    entries.removeAll { toRemove.contains($0.id) }
    AppLog.debug("pipeline", "Auto-pruned \(toRemove.count) terminal entries")
  }

  // MARK: - Processing

  private func processNext() {
    guard !isPaused, activeJobCount < maxConcurrentJobs else { return }

    let pending =
      entries
      .filter { $0.status == .queued }
      .sorted {
        $0.priority > $1.priority || ($0.priority == $1.priority && $0.queuedAt < $1.queuedAt)
      }

    guard let next = pending.first else { return }

    // Safety: if pipeline was never injected via setPipeline(), mark all queued
    // items as failed rather than leaving them stuck in "queued" state forever.
    guard let pipeline = self.pipeline else {
      AppLog.error(
        "pipeline",
        "Pipeline not set — aborting queue. \(pending.count) items will be marked failed.")
      #if DEBUG
        assertionFailure(
          "ProcessingQueueService.processNext() called before setPipeline(). "
            + "Fix initialization order in WawaNoteApp.init() — pipeline must be set before any enqueue."
        )
      #endif
      for entry in pending where entry.status == .queued {
        entry.status = .failed
        entry.completedAt = Date()
      }
      entries.removeAll {
        $0.status == .failed && Date().timeIntervalSince($0.completedAt ?? Date()) > 60
      }
      return
    }

    // Fetch item status before dispatching to pipeline
    let container = self.pipeline?.container
    guard let container else {
      AppLog.provider.error("ProcessingQueue: pipeline not configured, cannot create context")
      return
    }
    let preCtx = ModelContext(container)
    let nextItemID = next.itemID
    let preDesc = FetchDescriptor<KnowledgeItem>(
      predicate: #Predicate { $0.id == nextItemID })
    let preStatus = (try? preCtx.fetch(preDesc).first)?.statusRaw ?? "unknown"
    AppLog.event(
      "pipeline",
      "TRACE Processing item — itemID=\(next.itemID.uuidString.prefix(8)) preStatus=\(preStatus) priority=\(next.priority)"
    )

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
        // Terminal state guarantee ensures pipeline reaches .failed, .analyzed,
        // or .pendingReview on every exit path. No need to double-check.
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
          guard entries.contains(where: { $0.id == entryID && $0.status == .queued }) else {
            return
          }
          processNext()
        }
        return
      }
      entry.status = .failed
      entry.completedAt = Date()
      entry.lastError = error
      AppLog.error(
        "pipeline",
        "Processing permanently failed after \(entry.retryCount) retries — itemID=\(entry.itemID.uuidString.prefix(8))"
      )
    } else {
      entry.status = .done
      entry.completedAt = Date()
      AppLog.event("pipeline", "Processing complete — itemID=\(entry.itemID.uuidString.prefix(8))")
    }
    activeTasks[entryID] = nil
    activeJobCount = max(0, activeJobCount - 1)
    endBackgroundTask()
    sortEntries()
    autoPrune()
    processNext()
  }

  private func sortEntries() {
    entries.sort {
      $0.priority > $1.priority || ($0.priority == $1.priority && $0.queuedAt < $1.queuedAt)
    }
    for (idx, entry) in entries.enumerated() {
      entry.position = idx
    }
  }

  // MARK: - Background task

  private func beginBackgroundTask() {
    backgroundTaskCount += 1
    // Only request a system background task when the app is NOT in the
    // foreground. iOS kills apps that hold background tasks for >30s while
    // in the foreground — long transcriptions would trigger this timeout.
    // When the app is visible, we rely on the user keeping it open.
    guard backgroundTaskID == .invalid else { return }
    guard UIApplication.shared.applicationState != .active else {
      AppLog.debug("pipeline", "Skipping background task — app is in foreground")
      return
    }
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WawaQueue") {
      [weak self] in
      // Background task expiring — cancel active work to prevent iOS from
      // killing the app with a background task watchdog violation.
      Task { @MainActor [weak self] in
        AppLog.warn("pipeline", "Background task expiring — cancelling active jobs")
        for (_, task) in self?.activeTasks ?? [:] { task.cancel() }
        self?.endBackgroundTask()
      }
    }
    AppLog.debug("pipeline", "Started background task for transcription")
  }

  private func endBackgroundTask() {
    backgroundTaskCount -= 1
    guard backgroundTaskCount <= 0, backgroundTaskID != .invalid else { return }
    backgroundTaskCount = 0
    UIApplication.shared.endBackgroundTask(backgroundTaskID)
    backgroundTaskID = .invalid
  }
}
