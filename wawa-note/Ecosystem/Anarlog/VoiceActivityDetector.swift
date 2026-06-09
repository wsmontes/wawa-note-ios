import Foundation
import AVFoundation
import OSLog

// MARK: - Voice Activity Detector

/// Energy-based Voice Activity Detection for offline audio segmentation.
///
/// Inspired by anarlog's `vad` crate (Silero ONNX). Uses RMS energy
/// threshold instead of ML — faster, works on all iOS versions, no model needed.
///
/// For ML-based VAD in the future, Apple's SoundAnalysis framework
/// (SNClassifySoundRequest) can be used on iOS 15+, or the Silero ONNX
/// model can be converted to CoreML via coremltools.
///
/// Output: array of speech segments with start/end times, ready for
/// transcription or speaker labeling.
@MainActor
final class VoiceActivityDetector: ObservableObject {
    private let logger = Logger(subsystem: "com.wawa.note", category: "VAD")

    /// Minimum duration (seconds) for a speech segment to be considered valid.
    var minSpeechDuration: TimeInterval = 0.3

    /// Minimum silence duration (seconds) to split segments.
    var minSilenceDuration: TimeInterval = 0.5

    /// Energy threshold for RMS-based detection (0.0 - 1.0).
    /// 0.02 is a good default for close-mic recordings.
    /// Increase for noisy environments, decrease for quiet ones.
    var energyThreshold: Float = 0.02

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
    func extractSegments(from audioURL: URL, segments: [SpeechSegment]) throws -> [VADAudioSegment] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate

        return segments.map { segment in
            let startFrame = AVAudioFramePosition(segment.startTime * sampleRate)
            let frameCount = AVAudioFrameCount(segment.duration * sampleRate)
            return VADAudioSegment(
                startTime: segment.startTime,
                endTime: segment.endTime,
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
