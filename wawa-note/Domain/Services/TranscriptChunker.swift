import Foundation

struct TextChunk {
    let text: String
    let segmentRange: Range<Int>
}

final class TranscriptChunker: @unchecked Sendable {
    let maxCharsPerChunk = 24000  // ~6000 tokens
    let overlapSegments = 2

    func chunkTranscript(_ transcript: Transcript) -> [TextChunk] {
        let segments = transcript.segments
        guard !segments.isEmpty else { return [] }

        // Estimate total chars
        let totalChars = segments.reduce(0) { $0 + $1.text.count }
        if totalChars <= maxCharsPerChunk {
            let fullText = segments.map { "[\(formatTime($0.startTime))] \($0.text)" }.joined(separator: "\n")
            return [TextChunk(text: fullText, segmentRange: 0..<segments.count)]
        }

        var chunks: [TextChunk] = []
        var currentIndex = 0

        while currentIndex < segments.count {
            var chunkChars = 0
            var endIndex = currentIndex

            while endIndex < segments.count {
                let segChars = segments[endIndex].text.count
                if chunkChars + segChars > maxCharsPerChunk && endIndex > currentIndex {
                    break
                }
                chunkChars += segChars
                endIndex += 1
            }

            let range = currentIndex..<min(endIndex, segments.count)
            let chunkText = segments[range].map { "[\(formatTime($0.startTime))] \($0.text)" }.joined(separator: "\n")
            chunks.append(TextChunk(text: chunkText, segmentRange: range))

            // Move forward, keeping overlap
            currentIndex = max(currentIndex + 1, min(endIndex - overlapSegments, segments.count - 1))
            if currentIndex >= segments.count { break }
        }

        return chunks
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
