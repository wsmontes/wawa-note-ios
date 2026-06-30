import AVFoundation
import Foundation
import OSLog

/// Splits audio into speech-only segments using VoiceActivityDetector.
///
/// Guideline: "Não envie silêncio infinito para o transcritor.
/// Gating por VAD economiza CPU/bateria e reduz alucinações textuais."
///
/// Used before transcription to:
/// 1. Remove silent portions (saves CPU/battery on the transcriber)
/// 2. Apply pre/post speech padding for context
/// 3. Produce chunks sized for the transcription engine's limits
///
/// Unlike VADAudioChunker (which splits by fixed time), VADChunker
/// splits by actual speech boundaries — smarter and more efficient.
@MainActor
struct VADChunker {
  private let vad: VoiceActivityDetector
  private let maxChunkDuration: TimeInterval
  private let logger = Logger(subsystem: "com.wawa.note", category: "VADChunker")

  /// - Parameters:
  ///   - maxChunkDuration: Maximum seconds per chunk (engine limit, e.g. 50s for Apple Speech)
  init(maxChunkDuration: TimeInterval = 50) {
    self.vad = VoiceActivityDetector()
    self.maxChunkDuration = maxChunkDuration
    // Tune VAD for transcription pre-processing
    vad.energyThreshold = 0.03
    vad.minSpeechDuration = 0.5
    vad.minSilenceDuration = 0.3
    vad.preSpeechPad = 0.3
    vad.postSpeechPad = 0.4
  }

  /// Split an audio file into speech-only chunks.
  func chunkAudio(url: URL) async throws -> [VADAudioChunk] {
    // 1. Detect speech segments via VAD
    let segments = try vad.detectSpeech(in: url)

    guard !segments.isEmpty else {
      logger.info("VAD detected no speech — returning empty chunks")
      return []
    }

    logger.info(
      "VAD detected \(segments.count) speech segments: total=\(segments.map(\.duration).reduce(0, +))s"
    )

    // 2. Extract segments as audio chunks
    let vadSegments = try vad.extractSegments(from: url, segments: segments)

    // 3. Merge adjacent short segments that fit within maxChunkDuration
    let merged = mergeShortSegments(vadSegments, maxDuration: maxChunkDuration)

    // 4. Write each merged segment to a temporary file
    let audioFile = try AVAudioFile(forReading: url)
    let format = audioFile.processingFormat
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(
      "vad_chunks_\(UUID().uuidString.prefix(8))")
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

    var chunks: [VADAudioChunk] = []
    for (idx, vadSeg) in merged.enumerated() {
      let chunkURL = tempDir.appendingPathComponent("chunk_\(idx).caf")
      try writeChunk(
        from: url, startFrame: vadSeg.startFrame, frameCount: vadSeg.frameCount, format: format,
        to: chunkURL)
      chunks.append(
        VADAudioChunk(
          url: chunkURL, startTime: vadSeg.startTime, duration: vadSeg.endTime - vadSeg.startTime))
    }

    logger.info("VAD chunking complete: \(chunks.count) chunks from \(segments.count) segments")
    return chunks
  }

  /// Clean up temporary chunk files.
  func cleanup(chunks: [VADAudioChunk]) {
    guard let tempDir = chunks.first?.url.deletingLastPathComponent() else { return }
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Private

  /// Merge adjacent segments that together fit within maxChunkDuration.
  private func mergeShortSegments(_ segments: [VADAudioSegment], maxDuration: TimeInterval)
    -> [VADAudioSegment]
  {
    var merged: [VADAudioSegment] = []
    var current = segments[0]

    for next in segments.dropFirst() {
      let combinedDuration = next.endTime - current.startTime
      let gap = next.startTime - current.endTime

      if combinedDuration <= maxDuration && gap < 1.0 {
        // Merge: extend current to cover next
        current = VADAudioSegment(
          startTime: current.startTime,
          endTime: next.endTime,
          startFrame: current.startFrame,
          frameCount: AVAudioFrameCount(
            (next.endTime - current.startTime) * Double(current.frameCount)
              / (current.endTime - current.startTime)),
          confidence: max(current.confidence, next.confidence)
        )
      } else {
        // Can't merge: save current, start new
        if current.endTime - current.startTime > 0.5 {
          merged.append(current)
        }
        current = next
      }
    }

    // Don't forget the last one
    if current.endTime - current.startTime > 0.5 {
      merged.append(current)
    }

    return merged
  }

  /// Write a range of audio frames from source to a new file.
  private func writeChunk(
    from sourceURL: URL, startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount,
    format: AVAudioFormat, to destURL: URL
  ) throws {
    let sourceFile = try AVAudioFile(forReading: sourceURL)
    sourceFile.framePosition = startFrame

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      throw ChunkError.bufferAllocation
    }
    try sourceFile.read(into: buffer, frameCount: frameCount)

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: format.channelCount,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]

    let destFile = try AVAudioFile(
      forWriting: destURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
    try destFile.write(from: buffer)
  }

  enum ChunkError: Error, LocalizedError {
    case bufferAllocation
    var errorDescription: String? { "Failed to allocate audio buffer for VAD chunk" }
  }
}

// MARK: - VADAudioChunk (shared with VADAudioChunker)

struct VADAudioChunk {
  let url: URL
  let startTime: TimeInterval
  let duration: TimeInterval
}
