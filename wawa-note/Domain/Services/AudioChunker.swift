@preconcurrency import AVFoundation
import OSLog

// Related JIRA: KAN-542

struct AudioChunk {
  let url: URL
  let startTime: TimeInterval
  let duration: TimeInterval
  /// When non-zero, the first `overlapStart` seconds of this chunk overlap
  /// with the previous chunk and should be deduplicated.
  var overlapStart: TimeInterval = 0
}

final class AudioChunker: @unchecked Sendable {
  let chunkDuration: TimeInterval
  let overlap: TimeInterval

  var onProgress: (@Sendable (Int, Int) -> Void)?

  private let tempDir: URL = {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("audio_chunks", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  init(chunkDuration: TimeInterval = 600, overlap: TimeInterval = 2) {
    self.chunkDuration = chunkDuration
    self.overlap = overlap
  }

  deinit {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func getDuration(_ url: URL) -> Float64 {
    var fileID: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
      return 0
    }
    defer { AudioFileClose(fileID) }
    var duration: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &size, &duration)
    return duration
  }

  func splitAudio(url: URL) async throws -> [AudioChunk] {
    let totalSeconds = getDuration(url)

    guard totalSeconds > chunkDuration else {
      return [AudioChunk(url: url, startTime: 0, duration: totalSeconds)]
    }

    let asset = AVAsset(url: url)
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw NSError(
        domain: "chunk", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
    }

    // Build chunk descriptors
    struct ChunkDescriptor {
      let index: Int
      let start: TimeInterval
      let end: TimeInterval
      let url: URL
    }

    var descriptors: [ChunkDescriptor] = []
    var currentStart: TimeInterval = 0
    var idx = 0
    // overlap == 0 for remote engine (no dedup needed), >0 for on-device
    let effectiveOverlap = overlap > 0 && totalSeconds > chunkDuration ? overlap : 0

    while currentStart < totalSeconds {
      let chunkEnd = min(currentStart + chunkDuration, totalSeconds)
      let outputURL = tempDir.appendingPathComponent("chunk_\(idx).m4a")
      descriptors.append(
        ChunkDescriptor(index: idx, start: currentStart, end: chunkEnd, url: outputURL))
      // Advance by chunkDuration minus overlap so the next chunk includes
      // `overlap` seconds of context from the end of this chunk.
      currentStart = chunkEnd - effectiveOverlap
      idx += 1
    }

    let totalChunks = descriptors.count

    // Sequential export with progress reporting.
    // Skip chunks that already exist on disk (resume after crash/retry).
    var chunks: [AudioChunk] = []
    for desc in descriptors {
      try Task.checkCancellation()

      let fileExists = FileManager.default.fileExists(atPath: desc.url.path)
      if fileExists {
        // Chunk already exported (previous attempt). Validate it's non-empty.
        let attrs = try? FileManager.default.attributesOfItem(atPath: desc.url.path)
        let size = attrs?[.size] as? Int64 ?? 0
        if size > 1024 {
          // Valid existing chunk — skip export
          let hasOverlap = effectiveOverlap > 0 && desc.index > 0
          chunks.append(
            AudioChunk(
              url: desc.url, startTime: desc.start,
              duration: desc.end - desc.start,
              overlapStart: hasOverlap ? effectiveOverlap : 0))
          onProgress?(chunks.count, totalChunks)
          continue
        }
        // Corrupt/empty chunk — re-export
        try? FileManager.default.removeItem(at: desc.url)
      }

      try await exportChunk(
        asset: asset, audioTrack: audioTrack, start: desc.start, end: desc.end, url: desc.url)
      let hasOverlap = effectiveOverlap > 0 && desc.index > 0
      chunks.append(
        AudioChunk(
          url: desc.url, startTime: desc.start,
          duration: desc.end - desc.start,
          overlapStart: hasOverlap ? effectiveOverlap : 0))
      onProgress?(chunks.count, totalChunks)
    }

    AppLog.audio.info("Split into \(chunks.count) chunks (passthrough)")
    return chunks
  }

  // MARK: - Chunk export

  private func exportChunk(
    asset: AVAsset, audioTrack: AVAssetTrack, start: TimeInterval, end: TimeInterval, url: URL
  ) async throws {
    // Try passthrough first
    do {
      try await exportPassthrough(
        asset: asset, audioTrack: audioTrack, start: start, end: end, url: url)
      return
    } catch {
      AppLog.audio.warning(
        "Passthrough chunk export failed, falling back to re-encode: \(error.localizedDescription)")
    }

    // Fallback: use AVAssetExportSession (re-encode)
    let range = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      end: CMTime(seconds: end, preferredTimescale: 600)
    )

    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
    else {
      throw NSError(
        domain: "chunk", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
    }
    export.outputURL = url
    export.outputFileType = .m4a
    export.timeRange = range
    await export.export()

    if let error = export.error { throw error }
    guard export.status == .completed else {
      throw NSError(
        domain: "chunk", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Export status \(export.status.rawValue)"])
    }
  }

  private func exportPassthrough(
    asset: AVAsset, audioTrack: AVAssetTrack, start: TimeInterval, end: TimeInterval, url: URL
  ) async throws {
    try? FileManager.default.removeItem(at: url)

    guard let reader = try? AVAssetReader(asset: asset) else {
      throw NSError(
        domain: "chunk", code: -4, userInfo: [NSLocalizedDescriptionKey: "Cannot create reader"])
    }

    let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    reader.add(readerOutput)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      duration: CMTime(seconds: end - start, preferredTimescale: 600)
    )

    guard let writer = try? AVAssetWriter(url: url, fileType: .m4a) else {
      throw NSError(
        domain: "chunk", code: -5, userInfo: [NSLocalizedDescriptionKey: "Cannot create writer"])
    }

    let formatDescs = try await audioTrack.load(.formatDescriptions)
    let formatHint = formatDescs.first
    let writerInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil, sourceFormatHint: formatHint)
    writerInput.expectsMediaDataInRealTime = false
    writer.add(writerInput)

    guard reader.startReading() else {
      throw reader.error
        ?? NSError(
          domain: "chunk", code: -6, userInfo: [NSLocalizedDescriptionKey: "Reader failed to start"]
        )
    }
    guard writer.startWriting() else {
      throw writer.error
        ?? NSError(
          domain: "chunk", code: -7, userInfo: [NSLocalizedDescriptionKey: "Writer failed to start"]
        )
    }
    writer.startSession(atSourceTime: .zero)

    // We need to wait for the writer to finish on a non-MainActor thread
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let queue = DispatchQueue(label: "chunk.passthrough.\(UUID().uuidString)")
      let state = PassthroughExportState(
        reader: reader,
        readerOutput: readerOutput,
        writer: writer,
        writerInput: writerInput,
        continuation: continuation
      )
      writerInput.requestMediaDataWhenReady(on: queue) {
        state.drain()
      }
    } as Void
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: tempDir)
  }
}

/// Owns the non-Sendable AVFoundation reader/writer graph. AVFoundation invokes
/// `drain` only on the serial queue supplied to `requestMediaDataWhenReady`, and
/// completion is guarded so the checked continuation is resumed exactly once.
private final class PassthroughExportState: @unchecked Sendable {
  private let reader: AVAssetReader
  private let readerOutput: AVAssetReaderOutput
  private let writer: AVAssetWriter
  private let writerInput: AVAssetWriterInput
  private let continuation: CheckedContinuation<Void, Error>
  private let completionLock = NSLock()
  private var didComplete = false

  init(
    reader: AVAssetReader,
    readerOutput: AVAssetReaderOutput,
    writer: AVAssetWriter,
    writerInput: AVAssetWriterInput,
    continuation: CheckedContinuation<Void, Error>
  ) {
    self.reader = reader
    self.readerOutput = readerOutput
    self.writer = writer
    self.writerInput = writerInput
    self.continuation = continuation
  }

  func drain() {
    while writerInput.isReadyForMoreMediaData {
      guard let sample = readerOutput.copyNextSampleBuffer() else {
        writerInput.markAsFinished()
        writer.finishWriting { [self] in
          if writer.status == .completed {
            complete(with: .success(()))
          } else {
            complete(
              with: .failure(
                writer.error
                  ?? NSError(
                    domain: "chunk", code: -8,
                    userInfo: [NSLocalizedDescriptionKey: "Writer failed"])))
          }
        }
        return
      }

      guard writerInput.append(sample) else {
        reader.cancelReading()
        writer.cancelWriting()
        complete(
          with: .failure(
            writer.error
              ?? NSError(
                domain: "chunk", code: -9,
                userInfo: [NSLocalizedDescriptionKey: "Writer rejected audio sample"])))
        return
      }
    }
  }

  private func complete(with result: Result<Void, Error>) {
    completionLock.lock()
    guard !didComplete else {
      completionLock.unlock()
      return
    }
    didComplete = true
    completionLock.unlock()
    continuation.resume(with: result)
  }
}
