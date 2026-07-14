import AVFoundation
import Foundation
@preconcurrency import SwiftData
import WawaNoteCore

// Related JIRA: KAN-XX

/// Extracts text from audio items via transcription.
/// Handles all 17 error cases with structured ExtractionError codes.
/// Delegates engine selection to ContentExtractionService.resolveEngine().
final class AudioProcessor: ContentProcessor {

  private let fileStore: FileArtifactStore

  init(fileStore: FileArtifactStore = FileArtifactStore()) {
    self.fileStore = fileStore
  }

  // MARK: - ContentProcessor

  nonisolated
    func extract(from item: KnowledgeItem, context: ModelContext) async -> String?
  {
    guard !Task.isCancelled else {
      fail(item, context: context, error: .taskCancelled)
      return nil
    }

    // Resolve audio URL (sandbox or shared container for Share Extension imports)
    let sandboxURL = fileStore.audioFileURL(for: item.id)
    let sharedURL = fileStore.sharedAudioURL(for: item.id)
    let audioURL: URL
    if FileManager.default.fileExists(atPath: sandboxURL.path) {
      audioURL = sandboxURL
    } else if FileManager.default.fileExists(atPath: sharedURL.path) {
      audioURL = sharedURL
    } else {
      fail(item, context: context, error: .audioFileNotFound)
      return nil
    }

    // Validate audio
    let fileSize =
      (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
    guard fileSize > 4096 else {
      fail(item, context: context, error: .audioTooSmall)
      return nil
    }

    let duration = await audioDuration(url: audioURL)
    guard duration >= 1.0 else {
      fail(item, context: context, error: .audioTooShort)
      return nil
    }
    guard duration <= 7200 else {
      fail(item, context: context, error: .audioTooLong(duration))
      return nil
    }

    // Resolve engine (hop to MainActor for ContentExtractionService isolation)
    let engineOpt = await MainActor.run { ContentExtractionService.resolveEngine(context: context) }
    guard var engine = engineOpt else {
      fail(item, context: context, error: .noEngineAvailable)
      return nil
    }

    // Check availability
    let availability = engine.checkAvailability()
    switch availability {
    case .available: break
    case .permissionDenied:
      fail(item, context: context, error: .speechPermissionDenied)
      return nil
    case .modelMissing(let locale):
      fail(item, context: context, error: .modelNotInstalled(locale.identifier))
      return nil
    case .hardwareUnsupported:
      fail(item, context: context, error: .noEngineAvailable)
      return nil
    case .localeUnsupported:
      fail(item, context: context, error: .noEngineAvailable)
      return nil
    case .failed(let msg):
      fail(item, context: context, error: .engineError(msg))
      return nil
    }

    do {
      try await engine.prepareIfNeeded()
    } catch {
      fail(item, context: context, error: .engineError(error.localizedDescription))
      return nil
    }

    // Safe re-transcription: backup existing transcript
    let meetingDir = fileStore.meetingDirectoryURL(for: item.id)
    let transcriptURL = meetingDir.appendingPathComponent("transcript.json")
    let backupURL = meetingDir.appendingPathComponent("transcript.json.bak")
    let checkpointURL = meetingDir.appendingPathComponent("transcript_checkpoint.json")
    let isReTranscribing = FileManager.default.fileExists(atPath: transcriptURL.path)

    if isReTranscribing {
      try? FileManager.default.moveItem(at: transcriptURL, to: backupURL)
      try? FileManager.default.removeItem(at: checkpointURL)
    }

    // Checkpoint resume
    if let checkpoint = loadCheckpoint(itemID: item.id, meetingDir: meetingDir) {
      engine.resumeFromChunk = checkpoint.completedChunks
      engine.resumePreviousText = checkpoint.segments.map(\.text).joined(separator: " ")
    }

    // Wire checkpoint saver
    let itemID = item.id
    engine.onCheckpoint = { partialTranscript, completedChunks in
      let data = CheckpointData(
        completedChunks: completedChunks,
        segments: partialTranscript.segments,
        languageCode: partialTranscript.languageCode,
        savedAt: Date()
      )
      if let encoded = try? JSONEncoder().encode(data) {
        try? encoded.write(to: checkpointURL, options: .atomic)
      }
    }

    // Cancel monitor
    let monitor = Task { [engine] in
      while !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
      engine.cancel()
    }
    defer { monitor.cancel() }

    // Transcribe
    do {
      var result = try await engine.transcribeFile(audioURL, meetingId: item.id)

      // Merge checkpoint segments if resuming
      if let checkpoint = loadCheckpoint(itemID: itemID, meetingDir: meetingDir),
        !checkpoint.segments.isEmpty
      {
        var merged = checkpoint.segments
        merged.append(contentsOf: result.segments)
        result = Transcript(
          meetingId: itemID,
          languageCode: result.languageCode ?? checkpoint.languageCode,
          segments: merged,
          sourceEngineId: result.sourceEngineId
        )
      }

      engine.finalize()

      // Write transcript
      try fileStore.createMeetingDirectory(for: itemID)
      try fileStore.writeArtifact(result, fileName: "transcript.json", meetingId: itemID)
      try? FileManager.default.removeItem(at: checkpointURL)

      // Clean up backup on success
      if isReTranscribing { try? FileManager.default.removeItem(at: backupURL) }

      item.transcriptionEngineId = engine.id
      item.languageCode = result.languageCode
      context.safeSave(context: "audio-extraction-success", itemId: itemID)

      NotificationCenter.default.post(name: .transcriptReady, object: itemID.uuidString)
      return result.segments.map(\.text).joined(separator: "\n")

    } catch let error as TranscriptionError {
      // Restore backup on failure
      if isReTranscribing {
        try? FileManager.default.moveItem(at: backupURL, to: transcriptURL)
      }

      let extractionError = mapTranscriptionError(error)
      fail(item, context: context, error: extractionError)
      return nil
    } catch {
      if isReTranscribing {
        try? FileManager.default.moveItem(at: backupURL, to: transcriptURL)
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
      if msg.contains("429") { return .remoteRateLimited }
      if msg.contains("401") || msg.contains("403") { return .remoteAuthFailed }
      if msg.contains("500") || msg.contains("502") || msg.contains("503") {
        return .remoteServerError
      }
      if msg.contains("No speech") { return .noSpeechDetected }
      return .engineError(msg)
    }
  }

  private struct CheckpointData: Codable {
    let completedChunks: Int
    let segments: [TranscriptSegment]
    let languageCode: String?
    let savedAt: Date
  }

  private func loadCheckpoint(itemID: UUID, meetingDir: URL) -> CheckpointData? {
    let url = meetingDir.appendingPathComponent("transcript_checkpoint.json")
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let checkpoint = try? JSONDecoder().decode(CheckpointData.self, from: data),
      Date().timeIntervalSince(checkpoint.savedAt) < 86400
    else { return nil }
    return checkpoint
  }
}
