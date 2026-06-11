import Foundation
import AVFoundation

/// What kind of audio is available for playback/export.
enum AudioAssetState: Equatable, Sendable {
    /// No audio exists for this item.
    case unavailable
    /// A single audio.m4a file is ready (legacy or already concatenated).
    case singleFileReady(URL)
    /// Segmented recording: manifest + segment files exist, but audio.m4a
    /// has not been rendered yet. Call renderSingleFile() to concatenate.
    case segmentsAvailable(segmentCount: Int)
    /// Concatenation is in progress.
    case rendering
    /// Audio exists but could not be loaded (corrupt, missing, etc.).
    case failed(String)
}

/// Resolves playable/exportable audio for a KnowledgeItem, handling both
/// legacy single-file (audio.m4a) and segmented recordings (segments/ + manifest).
///
/// Single entry point for player and export — callers should ask this resolver
/// instead of checking `audioFileRelativePath` or constructing URLs directly.
final class AudioAssetResolver: Sendable {
    private let store: FileArtifactStore

    init(store: FileArtifactStore = FileArtifactStore()) {
        self.store = store
    }

    /// Current audio state for a knowledge item.
    func state(for itemId: UUID) -> AudioAssetState {
        let legacyURL = store.audioFileURL(for: itemId)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return .singleFileReady(legacyURL)
        }

        if store.recordingManifestExists(for: itemId),
           let manifest = try? store.readRecordingManifest(for: itemId) {
            let urls = manifest.segments
                .sorted { $0.index < $1.index }
                .map { store.segmentURL(for: itemId, fileName: $0.fileName) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }

            if !urls.isEmpty {
                return .segmentsAvailable(segmentCount: urls.count)
            }
        }

        return .unavailable
    }

    /// Resolve a playable URL, concatenating on demand if necessary.
    /// - Parameter itemId: The knowledge item ID.
    /// - Returns: URL to a playable audio file, or nil if no audio exists.
    func resolvePlayableURL(for itemId: UUID) async -> URL? {
        switch state(for: itemId) {
        case .singleFileReady(let url):
            return url
        case .segmentsAvailable:
            return await renderAndReturnSingleFile(for: itemId)
        case .unavailable, .failed, .rendering:
            return nil
        }
    }

    /// Render a single audio.m4a from segments on demand.
    /// Call this before playing or exporting when state is .segmentsAvailable.
    func renderSingleFile(for itemId: UUID) async {
        _ = await renderAndReturnSingleFile(for: itemId)
    }

    /// Resolve an exportable audio URL, rendering on demand if necessary.
    /// Throws if no audio is available or rendering fails.
    func resolveExportableURL(for itemId: UUID) async throws -> URL {
        switch state(for: itemId) {
        case .singleFileReady(let url):
            return url
        case .segmentsAvailable:
            guard let manifest = try? store.readRecordingManifest(for: itemId) else {
                throw AudioAssetError.manifestCorrupt
            }
            await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)
            let legacyURL = store.audioFileURL(for: itemId)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                return legacyURL
            }
            throw AudioAssetError.renderingFailed
        case .unavailable:
            throw AudioAssetError.noAudioAvailable
        case .rendering:
            throw AudioAssetError.alreadyRendering
        case .failed(let reason):
            throw AudioAssetError.assetFailed(reason)
        }
    }

    // MARK: - Private

    private func renderAndReturnSingleFile(for itemId: UUID) async -> URL? {
        guard let manifest = try? store.readRecordingManifest(for: itemId) else {
            return nil
        }
        await AudioSegmentConcatenator.concatenate(manifest: manifest, meetingId: itemId)
        let legacyURL = store.audioFileURL(for: itemId)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return nil
    }
}

enum AudioAssetError: Error, LocalizedError {
    case noAudioAvailable
    case manifestCorrupt
    case renderingFailed
    case alreadyRendering
    case assetFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioAvailable: "No audio available for this item."
        case .manifestCorrupt: "Recording manifest is damaged."
        case .renderingFailed: "Could not prepare audio for playback."
        case .alreadyRendering: "Audio is already being prepared."
        case .assetFailed(let reason): "Audio unavailable: \(reason)"
        }
    }
}
