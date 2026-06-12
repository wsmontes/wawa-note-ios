import AVFoundation
import OSLog

// MARK: - Segment concatenator (non-MainActor)

/// Concatenates recording segments into a single audio.m4a for legacy compatibility.
/// Used by AudioAssetResolver (on-demand playback) and RecordingCoordinator (post-stop).
enum AudioSegmentConcatenator {
    static func concatenate(manifest: RecordingManifest, meetingId: UUID) async {
        let store = FileArtifactStore()
        let sortedSegments = manifest.segments.sorted { $0.index < $1.index }

        let urls: [URL] = sortedSegments.compactMap { seg in
            let url = store.segmentURL(for: meetingId, fileName: seg.fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        guard urls.count > 1 else {
            if let src = urls.first {
                let dest = store.audioFileURL(for: meetingId)
                _ = try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: src, to: dest)
                } catch {
                    AppLog.audio.error("SegmentConcatenator: single-segment copy failed — src=\(src.lastPathComponent) error=\(error.localizedDescription)")
                }
            }
            return
        }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var skippedCount = 0
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
                } catch {
                    AppLog.audio.error("SegmentConcatenator: insertTimeRange failed for \(url.lastPathComponent) — error=\(error.localizedDescription)")
                    skippedCount += 1
                }
            } else {
                skippedCount += 1
            }
        }

        let destURL = store.audioFileURL(for: meetingId)
        _ = try? FileManager.default.removeItem(at: destURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            AppLog.audio.error("SegmentConcatenator: AVAssetExportSession creation failed — no output")
            return
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
        } else {
            let statusCode = export.status.rawValue
            AppLog.audio.error("SegmentConcatenator: export failed — status=\(statusCode) error=\(export.error?.localizedDescription ?? "nil")")
        }
    }
}
