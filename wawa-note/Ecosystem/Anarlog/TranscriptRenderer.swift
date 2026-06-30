import Foundation

/// Normalizes transcript output for readable rendering.
///
/// Ported from anarlog's `render.rs` — handles:
/// 1. Word spacing normalization ("do" + "'s" → " do's")
/// 2. Stable segment IDs (deterministic hash)
/// 3. Multi-transcript time offset alignment
/// 4. Markdown-formatted transcript output
enum TranscriptRenderer {

  // MARK: - Word normalization

  /// Normalize word spacing for readable output.
  ///
  /// Rules (from anarlog's `normalized_rendered_word_text`):
  /// - First word: trim leading whitespace
  /// - Subsequent words: add space prefix unless the word starts with punctuation
  ///   (`,`, `.`, `;`, `:`, `!`, `?`, `)`, `}`, `]`, `'`)
  static func normalizeWordSpacing(_ words: [String]) -> [String] {
    words.enumerated().map { index, word in
      if index == 0 {
        // First word: just trim leading whitespace
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " "))
      }

      let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: " "))

      // If already has leading space, keep as-is
      if word.hasPrefix(" ") { return word }

      // If starts with punctuation, no space needed
      if let first = trimmed.first, ",.;:!?)]}'\"".contains(first) {
        return trimmed
      }

      // Otherwise, add space prefix
      return " \(trimmed)"
    }
  }

  /// Normalize a full segment text from individual words.
  static func normalizeSegmentText(_ words: [TranscriptWord]) -> String {
    let normalized = normalizeWordSpacing(words.map(\.text))
    return normalized.joined()
  }

  // MARK: - Stable segment IDs

  /// Generate a stable, deterministic segment ID.
  ///
  /// Format: `channel:speakerIndex:humanID:firstWordAnchor:lastWordAnchor`
  /// This matches anarlog's `stable_segment_id` function.
  static func stableSegmentID(
    channel: Int,
    speakerIndex: Int?,
    speakerHumanID: String?,
    words: [TranscriptWord]
  ) -> String {
    let firstAnchor =
      words.first.map { w in
        w.id ?? "start:\(Int(w.startMs))"
      } ?? "none"

    let lastAnchor =
      words.last.map { w in
        w.id ?? "end:\(Int(w.endMs))"
      } ?? "none"

    let si = speakerIndex.map(String.init) ?? "none"
    let hid = speakerHumanID ?? "none"

    return "\(channel):\(si):\(hid):\(firstAnchor):\(lastAnchor)"
  }

  // MARK: - Time offset alignment

  /// Align timestamps across multiple transcript sources.
  /// Offsets later transcripts so their first word starts relative to
  /// the earliest transcript's start time.
  static func alignTimestamps(_ transcripts: [TranscriptTimeline]) -> [TranscriptTimeline] {
    guard let earliestStart = transcripts.compactMap(\.startedAt).min() else {
      return transcripts
    }

    return transcripts.map { transcript in
      guard let startedAt = transcript.startedAt else {
        return transcript  // No start time → anchor at 0
      }
      let offset = startedAt - earliestStart
      let offsetWords = transcript.words.map { word in
        TranscriptWord(
          id: word.id,
          text: word.text,
          startMs: word.startMs + offset,
          endMs: word.endMs + offset,
          channel: word.channel,
          speakerIndex: word.speakerIndex
        )
      }
      return TranscriptTimeline(startedAt: transcript.startedAt, words: offsetWords)
    }
  }

  // MARK: - Markdown rendering

  /// Render labeled segments as markdown transcript.
  /// Format: `**Speaker:** text`
  static func renderMarkdown(_ segments: [LabeledSegment]) -> String {
    segments.map { segment in
      "**\(segment.speaker):** \(segment.text)"
    }.joined(separator: "\n\n")
  }

  /// Render labeled segments as a simple speaker:text format.
  /// Format: `Speaker: text`
  static func renderPlain(_ segments: [LabeledSegment]) -> String {
    segments.map { segment in
      "\(segment.speaker): \(segment.text)"
    }.joined(separator: "\n")
  }
}

// MARK: - Supporting Types

/// A single transcript word with timing and channel info.
struct TranscriptWord: Codable {
  let id: String?
  let text: String
  let startMs: Double
  let endMs: Double
  let channel: Int
  var speakerIndex: Int?
}

/// A transcript timeline with optional absolute start time.
struct TranscriptTimeline {
  let startedAt: Double?  // Unix timestamp in ms
  let words: [TranscriptWord]
}
