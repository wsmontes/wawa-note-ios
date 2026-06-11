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
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: src, to: dest)
            }
            return
        }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for url in urls {
            // AVURLAsset.load(.tracks) and load(.duration) are the async
            // replacements for the deprecated synchronous AVAsset.tracks and
            // AVAsset.duration. Freshly-written WAV segments (especially from
            // Bluetooth HFP 8 kHz) may not have fully indexed metadata when
            // the synchronous APIs are called — they return nil/zero, silently
            // dropping segments from the concatenated output.
            let asset = AVURLAsset(url: url)
            guard let track = (try? await asset.load(.tracks))?.first(where: { $0.mediaType == .audio }) else { continue }
            let rawDuration = (try? await asset.load(.duration)) ?? .invalid
            // If async loading returned invalid/zero, use the full asset rather
            // than silently dropping the segment via a zero-length insert.
            let duration: CMTime = rawDuration.isValid && rawDuration > .zero ? rawDuration : .positiveInfinity
            if let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
                cursor = CMTimeAdd(cursor, duration)
            }
        }

        let destURL = store.audioFileURL(for: meetingId)
        try? FileManager.default.removeItem(at: destURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return }
        export.outputURL = destURL
        export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        if export.status == .completed {
            AppLog.event("audio", "Segments concatenated → audio.m4a (\(urls.count) segments)")
        }
    }
}
