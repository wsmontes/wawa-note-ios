import Foundation
import AVFoundation
import OSLog
// Related JIRA: KAN-6, KAN-23


// MARK: - Voice Activity Detector

/// Energy-based Voice Activity Detection for offline audio segmentation.
///
/// Thresholds tuned with Meetily's anti-fragmentation parameters:
/// - Speech threshold: 0.50 (prevents silence from leaking)
/// - Silence threshold: 0.35 (allows natural pauses)
/// - Min speech: 250ms (prevents Whisper-rejected <100ms fragments)
/// - Redemption time: 2000ms (bridges natural pauses, was capped at 400ms)
/// - Pre-speech pad: 300ms (context before speech)
/// - Post-speech pad: 400ms (context after speech)
///
/// Reference: Meetily's `vad.rs` — ContinuousVadProcessor with Silero VAD.
/// For ML-based VAD, convert Silero ONNX → CoreML via coremltools.
final class VoiceActivityDetector: ObservableObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.wawa.note", category: "VAD")

    /// Positive speech threshold — RMS level above this is definitely speech.
    /// Meetily default: 0.50 (higher = stricter, prevents false positives).
    var speechThreshold: Float = 0.05

    /// Minimum duration (seconds) for a speech segment to be valid.
    /// Meetily default: 250ms (prevents Whisper-rejected fragments <100ms).
    var minSpeechDuration: TimeInterval = 0.25

    /// Minimum silence duration (seconds) to split segments.
    /// Meetily default: 400ms (bridges natural pauses in speech).
    var minSilenceDuration: TimeInterval = 0.4

    /// Pre-speech padding (seconds) — audio context added before speech starts.
    /// Meetily default: 300ms. Applied during segment extraction.
    var preSpeechPad: TimeInterval = 0.3

    /// Post-speech padding (seconds) — audio context added after speech ends.
    /// Meetily default: 400ms. Applied during segment extraction.
    var postSpeechPad: TimeInterval = 0.4

    /// Legacy energy threshold (kept for compatibility).
    /// Use `speechThreshold` instead.
    var energyThreshold: Float {
        get { speechThreshold }
        set { speechThreshold = newValue }
    }

    // MARK: - Detection Result

    struct SpeechSegment: Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float  // 0-1, based on RMS relative to threshold
        let rms: Float

        var duration: TimeInterval { endTime - startTime }
    }

    // MARK: - Detection

    /// Detect speech segments using RMS energy threshold.
    /// Fast, works offline, no ML model needed.
    func detectSpeech(in audioURL: URL) throws -> [SpeechSegment] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let sampleRate = format.sampleRate

        // Read entire file into buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw VADError.bufferAllocationFailed
        }
        audioFile.framePosition = 0
        try audioFile.read(into: buffer, frameCount: buffer.frameCapacity)
        guard let channelData = buffer.floatChannelData else {
            throw VADError.noChannelData
        }

        let frameLength = Int(buffer.frameLength)
        let windowSize = Int(sampleRate * 0.1) // 100ms windows
        let minSilenceFrames = Int(sampleRate * minSilenceDuration)

        var segments: [SpeechSegment] = []
        var speechStart: Int?
        var silenceStart: Int?
        var currentRMS: Float = 0

        for i in stride(from: 0, to: frameLength, by: max(windowSize, 1)) {
            let windowEnd = min(i + windowSize, frameLength)
            let windowLength = windowEnd - i
            guard windowLength > 0 else { break }

            // Compute RMS for this window
            var sumSquares: Float = 0
            for j in 0..<windowLength {
                let sample = channelData[0][i + j]
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(windowLength))
            let isSpeech = rms > energyThreshold

            if isSpeech {
                if speechStart == nil {
                    speechStart = i
                }
                silenceStart = nil
                currentRMS = max(currentRMS, rms)
            } else {
                if let start = speechStart {
                    if silenceStart == nil {
                        silenceStart = i
                    }
                    let silenceDuration = i - (silenceStart ?? i)
                    if silenceDuration >= minSilenceFrames {
                        let segmentDuration = Double(i - start) / sampleRate
                        if segmentDuration >= minSpeechDuration {
                            segments.append(SpeechSegment(
                                startTime: Double(start) / sampleRate,
                                endTime: Double(i) / sampleRate,
                                confidence: min(currentRMS / (energyThreshold * 5), 1.0),
                                rms: currentRMS
                            ))
                        }
                        speechStart = nil
                        silenceStart = nil
                        currentRMS = 0
                    }
                }
            }
        }

        // Final segment
        if let start = speechStart {
            let segmentDuration = Double(frameLength - start) / sampleRate
            if segmentDuration >= minSpeechDuration {
                segments.append(SpeechSegment(
                    startTime: Double(start) / sampleRate,
                    endTime: Double(frameLength) / sampleRate,
                    confidence: min(currentRMS / (energyThreshold * 5), 1.0),
                    rms: currentRMS
                ))
            }
        }

        logger.info("VAD detected \(segments.count) speech segments (\(segments.map(\.duration).reduce(0, +))s total)")
        return segments
    }

    // MARK: - Segment extraction

    /// Extract speech segments as audio frame ranges for further processing.
    /// Applies pre/post speech padding to capture natural speech boundaries.
    func extractSegments(from audioURL: URL, segments: [SpeechSegment]) throws -> [VADAudioSegment] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = AVAudioFramePosition(audioFile.length)

        return segments.map { segment in
            // Apply pre-speech pad (context before speech onset)
            let paddedStart = max(0, segment.startTime - preSpeechPad)
            // Apply post-speech pad (context after speech end)
            let paddedEnd = min(Double(totalFrames) / sampleRate, segment.endTime + postSpeechPad)

            let startFrame = AVAudioFramePosition(paddedStart * sampleRate)
            let frameCount = AVAudioFrameCount((paddedEnd - paddedStart) * sampleRate)

            return VADAudioSegment(
                startTime: paddedStart,
                endTime: paddedEnd,
                startFrame: startFrame,
                frameCount: frameCount,
                confidence: segment.confidence
            )
        }
    }

    enum VADError: Error, LocalizedError {
        case bufferAllocationFailed
        case noChannelData

        var errorDescription: String? {
            switch self {
            case .bufferAllocationFailed: "Failed to allocate audio buffer"
            case .noChannelData: "No channel data in audio file"
            }
        }
    }
}

// MARK: - Supporting Types

struct VADAudioSegment: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let startFrame: AVAudioFramePosition
    let frameCount: AVAudioFrameCount
    let confidence: Float
}
