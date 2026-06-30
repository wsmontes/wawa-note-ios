import AVFoundation
import OSLog
import UIKit

// Related JIRA: KAN-5, KAN-20

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
/// Background protection: uses UIApplication.beginBackgroundTask to prevent iOS
/// from killing the process during export. Without this, a large WAV→M4A conversion
/// can be terminated mid-export, producing a file with no moov atom (unplayable).
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
            AppLog.audio.error("SegmentConcatenator: no segment files found for meeting \(meetingId.uuidString.prefix(8))")
            return false
        }

        let destURL = store.audioFileURL(for: meetingId)
        _ = try? FileManager.default.removeItem(at: destURL)

        // Request background execution time so iOS doesn't kill us mid-export.
        // Large WAV files (300MB+) can take 10-30s to encode.
        let bgTaskID = await withCheckedContinuation { (c: CheckedContinuation<UIBackgroundTaskIdentifier, Never>) in
            Task { @MainActor in
                let id = UIApplication.shared.beginBackgroundTask(withName: "WawaNote.Concat.\(meetingId.uuidString.prefix(8))") {
                    AppLog.audio.warning("SegmentConcatenator: background task expired during export")
                }
                c.resume(returning: id)
            }
        }
        defer {
            Task { @MainActor in
                if bgTaskID != .invalid { UIApplication.shared.endBackgroundTask(bgTaskID) }
            }
        }

        // Single segment: use AVAssetExportSession directly on the WAV source.
        // This properly encodes WAV/PCM → AAC/M4A in one pass.
        if urls.count == 1, let src = urls.first {
            let asset = AVURLAsset(url: src)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                AppLog.audio.error("SegmentConcatenator: single-segment export session creation failed")
                return false
            }
            export.outputURL = destURL
            export.outputFileType = .m4a
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { c.resume() }
            }
            if export.status == .completed {
                AppLog.event("audio", "Single segment exported → audio.m4a")
                return true
            } else {
                AppLog.audio.error(
                    "SegmentConcatenator: single-segment export failed — status=\(export.status.rawValue) error=\(export.error?.localizedDescription ?? "nil")")
                return false
            }
        }

        // Multi segment: build AVMutableComposition, then export as AAC/M4A.
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var skippedCount = 0
        var insertedSampleRates: [CMTimeScale] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = (try? await asset.load(.tracks))?.first(where: { $0.mediaType == .audio }) else {
                skippedCount += 1
                continue
            }
            let rawDuration = (try? await asset.load(.duration)) ?? .invalid
            guard rawDuration.isValid, rawDuration > .zero else {
                AppLog.audio.warning("SegmentConcatenator: skipping \(url.lastPathComponent) — invalid duration")
                skippedCount += 1
                continue
            }
            if let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: rawDuration), of: track, at: cursor)
                    cursor = CMTimeAdd(cursor, rawDuration)
                    let rate = track.naturalTimeScale
                    if rate > 0 { insertedSampleRates.append(rate) }
                } catch {
                    AppLog.audio.error("SegmentConcatenator: insertTimeRange failed for \(url.lastPathComponent) — error=\(error.localizedDescription)")
                    skippedCount += 1
                }
            } else {
                skippedCount += 1
            }
        }

        let uniqueRates = Set(insertedSampleRates)
        if uniqueRates.count > 1 {
            let ratesDesc = uniqueRates.sorted().map { "\($0) Hz" }.joined(separator: ", ")
            AppLog.audio.warning(
                "SegmentConcatenator: mixed sample rates [\(ratesDesc)] across \(urls.count) segments — AVFoundation will resample silently; quality may degrade (route change during BT HFP?)"
            )
        }

        guard skippedCount < urls.count else {
            AppLog.audio.error("SegmentConcatenator: all \(urls.count) segments skipped — no valid audio tracks")
            return false
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            AppLog.audio.error("SegmentConcatenator: multi-segment export session creation failed")
            return false
        }
        export.outputURL = destURL
        export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        if export.status == .completed {
            AppLog.event("audio", "Segments concatenated → audio.m4a (\(urls.count) segments)")
            if skippedCount > 0 {
                AppLog.audio.warning("SegmentConcatenator: \(skippedCount)/\(urls.count) segments skipped during concat")
            }
            return true
        } else {
            AppLog.audio.error(
                "SegmentConcatenator: multi-segment export failed — status=\(export.status.rawValue) error=\(export.error?.localizedDescription ?? "nil")")
            return false
        }
    }
}
