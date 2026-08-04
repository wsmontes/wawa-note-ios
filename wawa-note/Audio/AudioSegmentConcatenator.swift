import AVFoundation
import OSLog
import UIKit
import WawaNoteCore

// Related JIRA: KAN-545

// MARK: - Segment concatenator (non-MainActor)

/// Concatenates recording segments into a single audio.m4a (AAC).
/// Used by AudioAssetResolver (on-demand playback) and RecordingCoordinator (post-stop).
///
/// Single segment: WAV → AAC via AVAssetExportSession (proper transcode).
/// Multi segment: WAVs → composition → AAC via AVAssetExportSession.
///
/// All engines receive the same AAC/M4A file:
/// - Apple on-device/cloud: prepareForRecognition decodes AAC→16kHz WAV for SFSpeechRecognizer
/// - Whisper: AAC bytes sent directly via HTTP multipart
///
/// Background protection: uses BackgroundTaskManager (shared utility) to prevent
/// iOS from killing the process during export. Without this, a large WAV→M4A
/// conversion can be terminated mid-export, producing a file with no moov atom
/// (unplayable).
enum AudioSegmentConcatenator {
  /// Concatenate segments into audio.m4a. Returns true on success.
  @discardableResult
  static func concatenate(manifest: RecordingManifest, meetingId: UUID) async -> Bool {
    let store = FileArtifactStore()
    let sortedSegments = manifest.segments.sorted { $0.index < $1.index }

    let urls: [URL] = sortedSegments.compactMap { seg in
      let url = store.segmentURL(for: meetingId, fileName: seg.fileName)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    guard !urls.isEmpty else {
      AppLog.audio.error(
        "SegmentConcatenator: no segment files found for meeting \(meetingId.uuidString.prefix(8))")
      return false
    }

    let destURL = store.audioFileURL(for: meetingId)
    // Export to a sibling temporary file. A recovery may be running against an
    // existing playable M4A, and a failed export must never destroy that source
    // artifact before its replacement has been validated.
    let temporaryURL = destURL.deletingLastPathComponent()
      .appendingPathComponent("audio-rebuilding-\(UUID().uuidString).m4a")
    _ = try? FileManager.default.removeItem(at: temporaryURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    // Request background execution time so iOS doesn't kill us mid-export.
    // Large WAV files (300MB+) can take 10-30s to encode. Uses the shared
    // BackgroundTaskManager instead of raw UIBackgroundTaskIdentifier.
    let bgTask = await MainActor.run { () -> BackgroundTaskManager in
      let mgr = BackgroundTaskManager()
      mgr.begin("WawaNote.Concat.\(meetingId.uuidString.prefix(8))")
      return mgr
    }
    defer {
      Task { @MainActor in
        bgTask.end()
      }
    }

    // Single segment: use AVAssetExportSession directly on the WAV source.
    // This properly encodes WAV/PCM → AAC/M4A in one pass.
    if urls.count == 1, let src = urls.first {
      let asset = AVURLAsset(url: src)
      guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
      else {
        AppLog.audio.error("SegmentConcatenator: single-segment export session creation failed")
        return false
      }
      export.outputURL = temporaryURL
      export.outputFileType = .m4a
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        export.exportAsynchronously { c.resume() }
      }
      if export.status == .completed {
        return replaceAudio(at: destURL, with: temporaryURL, description: "Single segment exported")
      } else {
        AppLog.audio.error(
          "SegmentConcatenator: single-segment export failed — status=\(export.status.rawValue) error=\(export.error?.localizedDescription ?? "nil")"
        )
        return false
      }
    }

    // Multi segment: build AVMutableComposition, then export as AAC/M4A.
    let composition = AVMutableComposition()
    var cursor = CMTime.zero
    var skippedCount = 0
    for url in urls {
      let asset = AVURLAsset(url: url)
      guard let track = (try? await asset.load(.tracks))?.first(where: { $0.mediaType == .audio })
      else {
        skippedCount += 1
        continue
      }
      let rawDuration = (try? await asset.load(.duration)) ?? .invalid
      guard rawDuration.isValid, rawDuration > .zero else {
        AppLog.audio.warning(
          "SegmentConcatenator: skipping \(url.lastPathComponent) — invalid duration")
        skippedCount += 1
        continue
      }
      if let compTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      {
        do {
          try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: rawDuration), of: track, at: cursor)
          cursor = CMTimeAdd(cursor, rawDuration)
        } catch {
          AppLog.audio.error(
            "SegmentConcatenator: insertTimeRange failed for \(url.lastPathComponent) — error=\(error.localizedDescription)"
          )
          skippedCount += 1
        }
      } else {
        skippedCount += 1
      }
    }

    guard
      let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else {
      AppLog.audio.error("SegmentConcatenator: multi-segment export session creation failed")
      return false
    }
    export.outputURL = temporaryURL
    export.outputFileType = .m4a
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      export.exportAsynchronously { c.resume() }
    }
    if export.status == .completed {
      guard
        replaceAudio(
          at: destURL, with: temporaryURL,
          description: "Segments concatenated (\(urls.count) segments)"
        )
      else { return false }
      if skippedCount > 0 {
        AppLog.audio.warning(
          "SegmentConcatenator: \(skippedCount)/\(urls.count) segments skipped during concat")
      }
      return true
    } else {
      AppLog.audio.error(
        "SegmentConcatenator: multi-segment export failed — status=\(export.status.rawValue) error=\(export.error?.localizedDescription ?? "nil")"
      )
      return false
    }
  }

  /// Replaces the consolidated artifact only after AVFoundation has completed
  /// a valid export. This preserves the previous recording if a retry fails.
  private static func replaceAudio(
    at destinationURL: URL, with temporaryURL: URL, description: String
  ) -> Bool {
    do {
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        _ = try FileManager.default.replaceItemAt(
          destinationURL, withItemAt: temporaryURL, backupItemName: nil,
          options: .usingNewMetadataOnly)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
      }
      AppLog.event("audio", "\(description) → audio.m4a")
      return true
    } catch {
      AppLog.audio.error(
        "SegmentConcatenator: could not commit consolidated audio — \(error.localizedDescription)"
      )
      return false
    }
  }
}
