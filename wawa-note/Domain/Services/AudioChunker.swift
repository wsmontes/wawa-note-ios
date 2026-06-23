@preconcurrency import AVFoundation
import OSLog

struct AudioChunk {
    let url: URL
    let startTime: TimeInterval
    let duration: TimeInterval
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
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return 0 }
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
            throw NSError(domain: "chunk", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
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

        while currentStart < totalSeconds {
            let chunkEnd = min(currentStart + chunkDuration, totalSeconds)
            let outputURL = tempDir.appendingPathComponent("chunk_\(idx).wav")
            descriptors.append(ChunkDescriptor(index: idx, start: currentStart, end: chunkEnd, url: outputURL))
            currentStart = chunkEnd
            idx += 1
        }

        let totalChunks = descriptors.count

        // Sequential export with progress reporting
        var chunks: [AudioChunk] = []
        for desc in descriptors {
            try await exportChunk(asset: asset, audioTrack: audioTrack, start: desc.start, end: desc.end, url: desc.url)
            chunks.append(AudioChunk(url: desc.url, startTime: desc.start, duration: desc.end - desc.start))
            onProgress?(chunks.count, totalChunks)
        }

        AppLog.audio.info("Split into \(chunks.count) chunks (PCM WAV 16kHz mono)")
        return chunks
    }

    // MARK: - Chunk export (PCM WAV output for SFSpeechRecognizer compatibility — KAN-73)

    private func exportChunk(asset: AVAsset, audioTrack: AVAssetTrack, start: TimeInterval, end: TimeInterval, url: URL) async throws {
        try? FileManager.default.removeItem(at: url)

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NSError(domain: "chunk", code: -4, userInfo: [NSLocalizedDescriptionKey: "Cannot create reader"])
        }

        // Decode to PCM 16-bit 16kHz mono — optimal for speech recognition
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
        reader.add(readerOutput)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )

        guard let writer = try? AVAssetWriter(url: url, fileType: .wav) else {
            throw NSError(domain: "chunk", code: -5, userInfo: [NSLocalizedDescriptionKey: "Cannot create WAV writer"])
        }

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "chunk", code: -6, userInfo: [NSLocalizedDescriptionKey: "Reader failed to start"])
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "chunk", code: -7, userInfo: [NSLocalizedDescriptionKey: "Writer failed to start"])
        }
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "chunk.pcm.\(UUID().uuidString)")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: writer.error ?? NSError(domain: "chunk", code: -8, userInfo: [NSLocalizedDescriptionKey: "WAV writer failed"]))
                            }
                        }
                        return
                    }
                }
            }
        } as Void

        AppLog.audio.info("Exported PCM WAV chunk: \(url.lastPathComponent) (\(end - start)s)")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
