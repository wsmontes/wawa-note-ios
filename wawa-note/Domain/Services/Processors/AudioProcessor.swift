import AVFoundation
import Foundation
@preconcurrency import SwiftData
import WawaNoteCore

// Related JIRA: KAN-546

/// Extracts text from audio items via transcription.
/// Handles all 17 error cases with structured ExtractionError codes.
/// Delegates engine selection to ContentExtractionService.resolveEngine().
final class AudioProcessor: ContentProcessor {

  private let fileStore: FileArtifactStore

  init(fileStore: FileArtifactStore = FileArtifactStore()) {
    self.fileStore = fileStore
  }

  // MARK: - ContentProcessor

  func extract(from item: KnowledgeItem, context: ModelContext) async -> String? {
    // Signal that extract() was actually entered
    try? "entered".write(
      toFile: NSHomeDirectory() + "/Documents/.extract_entered", atomically: true, encoding: .utf8)
    AppLog.transcription.error(
      "🔊 AP: extract starting — item=\(item.id.uuidString.prefix(8)) type=\(item.type.rawValue)")

    guard !Task.isCancelled else {
      AppLog.transcription.error("🔊 AP: extract cancelled at entry")
      try? "cancelled_at_entry".write(
        toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
      AppLog.transcription.info("AP: cancelled before start")
      fail(item, context: context, error: .taskCancelled)
      return nil
    }

    // Resolve audio URL (sandbox or shared container for Share Extension imports)
    let sandboxURL = fileStore.audioFileURL(for: item.id)
    let sharedURL = fileStore.sharedAudioURL(for: item.id)
    let audioURL: URL
    if FileManager.default.fileExists(atPath: sandboxURL.path) {
      audioURL = sandboxURL
      AppLog.transcription.info("AP: using sandbox audio URL")
    } else if FileManager.default.fileExists(atPath: sharedURL.path) {
      audioURL = sharedURL
      AppLog.transcription.info("AP: using shared container audio URL")
    } else {
      AppLog.transcription.error("AP: audio file not found at either path")
      fail(item, context: context, error: .audioFileNotFound)
      return nil
    }

    // Validate audio
    let fileSize =
      (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
    AppLog.transcription.info("AP: audio size=\(fileSize) bytes")
    try? "size_ok".write(
      toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
    guard fileSize > 4096 else {
      AppLog.transcription.error("AP: audio too small (\(fileSize) bytes)")
      fail(item, context: context, error: .audioTooSmall)
      return nil
    }

    let duration = await audioDuration(url: audioURL)
    try? "duration_\(String(format: "%.0f", duration))s".write(
      toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
    AppLog.transcription.info("AP: audio duration=\(String(format: "%.1f", duration))s")
    guard duration >= 1.0 else {
      fail(item, context: context, error: .audioTooShort)
      return nil
    }
    guard duration <= 7200 else {
      fail(item, context: context, error: .audioTooLong(duration))
      return nil
    }

    // Resolve engine (hop to MainActor for ContentExtractionService isolation)
    AppLog.transcription.error("🔊 AP: resolving engine...")
    let engineOpt = await MainActor.run { ContentExtractionService.resolveEngine(context: context) }
    guard var engine = engineOpt else {
      AppLog.transcription.error("🔊 AP: no engine available")
      fail(item, context: context, error: .noEngineAvailable)
      return nil
    }
    try? "engine_\(engine.id)".write(
      toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
    AppLog.transcription.error("🔊 AP: engine resolved — id=\(engine.id)")

    // Check availability
    AppLog.transcription.error("🔊 AP: checking availability...")
    let availability = engine.checkAvailability()
    switch availability {
    case .available:
      AppLog.transcription.error("🔊 AP: engine available")
    case .permissionDenied:
      AppLog.transcription.error("🔊 AP: permission denied")
      fail(item, context: context, error: .speechPermissionDenied)
      return nil
    case .modelMissing(let locale):
      AppLog.transcription.error("🔊 AP: model missing for \(locale.identifier)")
      fail(item, context: context, error: .modelNotInstalled(locale.identifier))
      return nil
    case .hardwareUnsupported:
      AppLog.transcription.error("🔊 AP: hardware unsupported")
      fail(item, context: context, error: .noEngineAvailable)
      return nil
    case .localeUnsupported:
      AppLog.transcription.error("🔊 AP: locale unsupported")
      fail(item, context: context, error: .noEngineAvailable)
      return nil
    case .failed(let msg):
      AppLog.transcription.error("🔊 AP: engine failed — \(msg)")
      fail(item, context: context, error: .engineError(msg))
      return nil
    }

    do {
      AppLog.transcription.error("🔊 AP: preparing engine...")
      try? "preparing".write(
        toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
      try await engine.prepareIfNeeded()
      AppLog.transcription.error("🔊 AP: engine ready, calling transcribeFile...")
      try? "prepared".write(
        toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
    } catch {
      AppLog.transcription.error("🔊 AP: prepare failed — \(error.localizedDescription)")
      fail(item, context: context, error: .engineError(error.localizedDescription))
      return nil
    }

    // Safe re-transcription: backup existing transcript with unique name.
    // Using a timestamped backup prevents a stale .bak from silently destroying
    // the original transcript (the dead-path ContentPipelineService already does this).
    let meetingDir = fileStore.meetingDirectoryURL(for: item.id)
    let transcriptURL = meetingDir.appendingPathComponent("transcript.json")
    let checkpointURL = meetingDir.appendingPathComponent("transcript_checkpoint.json")
    let isReTranscribing = FileManager.default.fileExists(atPath: transcriptURL.path)

    // Snapshot checkpoint BEFORE deleting or transcribing.
    // The onCheckpoint callback overwrites this file during the run, so we must
    // capture the pre-run state for correct merge (AudioProcessor 11a fix).
    let preRunCheckpoint = loadCheckpoint(
      itemID: item.id, meetingDir: meetingDir, engineId: engine.id)
    var backupURL: URL?

    if isReTranscribing {
      // Remove any stale .bak first (BUG 4 fix: timestamped backup name).
      backupURL = meetingDir.appendingPathComponent(
        "transcript_\(Int(Date().timeIntervalSince1970)).json.bak")
      // Only remove the specific backup file we're about to create, not all
      // .bak files. A concurrent pipeline (ContentPipelineService) may have
      // its own backup in the same directory.
      try? FileManager.default.removeItem(at: backupURL!)
      try? FileManager.default.moveItem(at: transcriptURL, to: backupURL!)
      try? FileManager.default.removeItem(at: checkpointURL)
    }

    // Resume from pre-run checkpoint snapshot (A1 fix: loaded BEFORE delete above)
    if let checkpoint = preRunCheckpoint {
      engine.resumeFromChunk = checkpoint.completedChunks
      engine.resumePreviousText = checkpoint.segments.map(\.text).joined(separator: " ")
    }

    // Wire checkpoint saver
    let itemID = item.id
    // Issue 5 fix: the engine's onCheckpoint only includes segments from
    // THIS run (chunks after resumeFromChunk), so a resumed run that writes
    // a checkpoint overwrites the pre-resume chunks on disk. Merge pre-run
    // segments so the on-disk checkpoint is always cumulative.
    let preResumeSegments = preRunCheckpoint?.segments ?? []
    engine.onCheckpoint = { partialTranscript, completedChunks in
      let mergedSegments = preResumeSegments + partialTranscript.segments
      let data = CheckpointData(
        completedChunks: completedChunks,
        segments: mergedSegments,
        languageCode: partialTranscript.languageCode ?? preRunCheckpoint?.languageCode,
        savedAt: Date(),
        engineId: engine.id
      )
      if let encoded = try? JSONEncoder().encode(data) {
        try? encoded.write(to: checkpointURL, options: .atomic)
      }
    }

    // Transcribe with proper cancellation propagation.
    // withTaskCancellationHandler ensures engine.cancel() is called
    // immediately when the parent task is cancelled, rather than relying
    // on an unstructured child Task that doesn't inherit cancellation.
    do {
      // Capture a local let copy for the @Sendable onCancel closure.
      // engine is a var (mutated for resumeFromChunk/resumePreviousText)
      // so it can't be captured directly in concurrently-executing code.
      let engineRef = engine
      try? "calling_transcribe".write(
        toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
      // Pass language hint to Whisper API: prevents wrong-language hallucination
      // on silent/noisy audio by telling Whisper which language to expect.
      if let langCode = item.languageCode {
        engine.languageHint = normalizeBCP47(langCode)
      }
      AppLog.transcription.error(
        "🔊 AP: calling engine.transcribeFile — audio=\(audioURL.lastPathComponent) language=\(engine.languageHint ?? "auto")"
      )
      var result = try await withTaskCancellationHandler {
        try await engine.transcribeFile(audioURL, meetingId: item.id)
      } onCancel: {
        AppLog.transcription.error("🔊 AP: transcription cancelled!")
        engineRef.cancel()
      }
      try? "transcribe_done".write(
        toFile: NSHomeDirectory() + "/Documents/.extract_step", atomically: true, encoding: .utf8)
      AppLog.transcription.error(
        "🔊 AP: transcribeFile returned — \(result.segments.count) segments")

      // Merge pre-run checkpoint segments if resuming (11a fix: use snapshot
      // captured BEFORE transcription, not the checkpoint that onCheckpoint
      // overwrote during this run — that already contains the full result).
      //
      // Round 2 fix: non-chunking engines (SpeechAnalyzer) re-transcribe the
      // entire file, so result.segments already covers the full duration.
      // Merging with preRunCheckpoint duplicates the first part. Dedup by
      // start time, keeping the result (newer) segment when timestamps overlap.
      if let checkpoint = preRunCheckpoint, !checkpoint.segments.isEmpty {
        var merged = checkpoint.segments
        merged.append(contentsOf: result.segments)
        // Dedup: group by start time (1s granularity), keep latest
        var seen = Set<Int>()
        var deduped: [TranscriptSegment] = []
        for seg in merged.reversed() {
          let bucket = Int(seg.startTime)
          if !seen.contains(bucket) {
            seen.insert(bucket)
            deduped.append(seg)
          }
        }
        result = Transcript(
          meetingId: itemID,
          languageCode: result.languageCode ?? checkpoint.languageCode,
          segments: deduped.reversed(),
          sourceEngineId: result.sourceEngineId
        )
      }

      engine.finalize()

      // ── Post-processing: filter hallucinated segments ──
      let validation = TranscriptValidator.validate(
        result.segments, expectedLanguage: result.languageCode ?? "en")
      if !validation.discarded.isEmpty {
        AppLog.transcription.warning(
          "AP: TranscriptValidator discarded \(validation.discarded.count)/\(result.segments.count) segments"
        )
      }
      guard !validation.kept.isEmpty else {
        AppLog.transcription.error(
          "AP: all segments discarded by TranscriptValidator — treating as no speech")
        throw TranscriptionError.recognitionFailed(
          "All \(result.segments.count) transcript segments failed validation")
      }
      result = Transcript(
        meetingId: result.meetingId,
        languageCode: result.languageCode,
        segments: validation.kept,
        sourceEngineId: result.sourceEngineId,
        createdAt: result.createdAt)

      // Write transcript
      try fileStore.createMeetingDirectory(for: itemID)
      try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: itemID)
      try? FileManager.default.removeItem(at: checkpointURL)

      item.transcriptionEngineId = engine.id
      item.languageCode = result.languageCode
      let didSave = context.safeSave(context: "audio-extraction-success", itemId: itemID)

      // Atomicity guard: if the status save failed, the transcript.json on disk
      // is inconsistent with SwiftData state. Delete the transcript so the item
      // can be re-processed instead of appearing "transcribed" with no status.
      guard didSave else {
        AppLog.transcription.error("AP: safeSave failed — rolling back transcript.json")
        try? FileManager.default.removeItem(at: transcriptURL)
        // Issue 2 fix: backup was deleted BEFORE safeSave (line 226 in old code),
        // making this restore dead. Now backup is preserved until after the guard.
        if let backupURL {
          try? FileManager.default.moveItem(at: backupURL, to: transcriptURL)
        }
        fail(item, context: context, error: .engineError("Failed to persist transcription status"))
        return nil
      }

      // Clean up backup ONLY after confirming safeSave succeeded.
      // Previously this ran before the guard, destroying the backup needed
      // for rollback (Issue 2 — dead-code atomicity guard).
      if let backupURL { try? FileManager.default.removeItem(at: backupURL) }

      NotificationCenter.default.post(name: .transcriptReady, object: itemID.uuidString)
      return result.segments.map(\.text).joined(separator: "\n")

    } catch let error as TranscriptionError {
      // Restore backup on failure
      if let backupURL {
        try? FileManager.default.moveItem(at: backupURL, to: transcriptURL)
      }

      // Issue 10 fix: cancellation is not a failure — roll back to .recorded
      // so the item can be re-processed later. The pipeline defer will accept
      // .recorded as a valid non-failed state.
      if case .cancelled = error {
        item.status = .recorded
        item.lastErrorRaw = nil
        context.safeSave(context: "audio-extraction-cancelled", itemId: itemID)
        return nil
      }

      let extractionError = mapTranscriptionError(error)
      fail(item, context: context, error: extractionError)
      return nil
    } catch {
      if let backupURL {
        try? FileManager.default.moveItem(at: backupURL, to: transcriptURL)
      }
      // CancellationError from Task.checkCancellation should also roll back
      if error is CancellationError {
        item.status = .recorded
        item.lastErrorRaw = nil
        context.safeSave(context: "audio-extraction-cancelled", itemId: itemID)
        return nil
      }
      fail(item, context: context, error: .engineError(error.localizedDescription))
      return nil
    }
  }

  // MARK: - Private

  private func fail(_ item: KnowledgeItem, context: ModelContext, error: ExtractionError) {
    item.status = .failed
    item.lastErrorRaw = error.errorDescription
    context.safeSave(context: "audio-extraction-failed", itemId: item.id)
  }

  private func audioDuration(url: URL) async -> Double {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return 0 }
    let secs = CMTimeGetSeconds(duration)
    return (secs.isNaN || secs.isInfinite || secs <= 0) ? 0 : secs
  }

  /// Normalize a language identifier to BCP-47 format.
  /// Converts plain names ("english") to codes ("en") for the Whisper API.
  private func normalizeBCP47(_ code: String) -> String {
    let lower = code.lowercased().trimmingCharacters(in: .whitespaces)
    // Already BCP-47 (e.g. "en", "pt-BR", "en-US")
    if lower.count <= 5 && lower.contains("-") || lower.count == 2 { return lower }
    // Plain names → codes
    switch lower {
    case "english": return "en"
    case "portuguese": return "pt"
    case "spanish": return "es"
    case "french": return "fr"
    case "german": return "de"
    case "italian": return "it"
    case "japanese": return "ja"
    case "korean": return "ko"
    case "chinese": return "zh"
    case "russian": return "ru"
    case "arabic": return "ar"
    case "hindi": return "hi"
    case "dutch": return "nl"
    default: return "en"  // safe default
    }
  }

  private func mapTranscriptionError(_ error: TranscriptionError) -> ExtractionError {
    switch error {
    case .notAuthorized: return .speechPermissionDenied
    case .cancelled: return .taskCancelled
    case .noSupportedLocale: return .noEngineAvailable
    case .fileTooLarge: return .remoteFileTooLarge
    case .fileTooLongForLocal: return .audioTooLong(7200)
    case .modelNotInstalled(let locale): return .modelNotInstalled(locale)
    case .onDeviceUnavailable: return .noEngineAvailable
    case .recognitionFailed(let msg):
      if msg.contains("timed out") { return .recognitionTimedOut }
      if msg.contains("413") { return .remoteFileTooLarge }
      if msg.contains("no credits") || msg.contains("billing") || msg.contains("insufficient_quota")
      {
        return .remoteAuthFailed
      }
      if msg.contains("429") { return .remoteRateLimited }
      if msg.contains("401") || msg.contains("403") { return .remoteAuthFailed }
      if msg.contains("500") || msg.contains("502") || msg.contains("503") {
        return .remoteServerError
      }
      if msg.contains("No speech") { return .noSpeechDetected }
      return .engineError(msg)
    case .quotaExhausted:
      return .remoteAuthFailed
    }
  }

  private struct CheckpointData: Codable {
    let completedChunks: Int
    let segments: [TranscriptSegment]
    let languageCode: String?
    let savedAt: Date
    let engineId: String?
  }

  private func loadCheckpoint(itemID: UUID, meetingDir: URL, engineId: String) -> CheckpointData? {
    let url = meetingDir.appendingPathComponent("transcript_checkpoint.json")
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let checkpoint = try? JSONDecoder().decode(CheckpointData.self, from: data),
      Date().timeIntervalSince(checkpoint.savedAt) < 86400
    else { return nil }
    // Issue 7 fix: discard checkpoint if engine changed (Apple 50s chunks vs
    // Remote 600s chunks — resuming at wrong indices silently corrupts transcript).
    if let checkpointEngineId = checkpoint.engineId, checkpointEngineId != engineId {
      AppLog.transcription.warning(
        "AP: discarding checkpoint — engine changed from \(checkpointEngineId) to \(engineId)")
      return nil
    }
    return checkpoint
  }
}
