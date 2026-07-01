import Foundation
import WawaNoteCore

/// Assigns human-readable speaker labels to transcript segments.
///
/// Ported from anarlog's `SpeakerLabeler` in `crates/transcript/src/label.rs`.
///
/// Algorithm:
/// 1. Known speaker with human_id → use their name
/// 2. DirectMic channel without speaker_index → "You" (the self)
/// 3. Same channel + speaker_index across segments → same unknown speaker ("Speaker N")
/// 4. Distinct channel/index combos → distinct "Speaker N" labels
///
/// The labeler is stateful — calling `label(for:)` multiple times with
/// the same segment key returns the same label.
struct SpeakerLabeler {
  /// Context for known speakers: maps human_id → display name
  struct SpeakerContext {
    var selfHumanID: String?
    var humanNameByID: [String: String] = [:]
    var participants: [AnarlogParticipant] = []

    init(selfHumanID: String? = nil, participants: [AnarlogParticipant] = []) {
      self.selfHumanID = selfHumanID
      self.participants = participants
      for p in participants {
        humanNameByID[p.name] = p.name
        if let title = p.jobTitle {
          humanNameByID[p.name] = "\(p.name) (\(title))"
        }
      }
    }
  }

  // MARK: - Segment Key

  /// Unique identifier for a speaker within a transcript.
  /// Matches anarlog's `SegmentKey` structure.
  struct SegmentKey: Hashable {
    /// Audio channel: 0 = DirectMic (self), 1+ = other participants
    let channel: Int
    /// Provider-assigned speaker index (optional)
    let speakerIndex: Int?
    /// Human-readable ID (optional, from identity assignment)
    let speakerHumanID: String?

    init(channel: Int, speakerIndex: Int? = nil, speakerHumanID: String? = nil) {
      self.channel = channel
      self.speakerIndex = speakerIndex
      self.speakerHumanID = speakerHumanID
    }

    /// Whether this key represents a known (named) speaker.
    func isKnownSpeaker(context: SpeakerContext?) -> Bool {
      if speakerHumanID != nil { return true }
      // DirectMic without speaker_index → likely the self
      if channel == 0, speakerIndex == nil,
        context?.selfHumanID != nil
      {
        return true
      }
      return false
    }

    /// Match participants to channel assignments.
    /// DirectMic (channel 0) → first participant or self.
    func label(context: SpeakerContext?, labeler: inout SpeakerLabeler) -> String {
      // 1. Has human ID → use name from context
      if let humanID = speakerHumanID {
        if let name = context?.humanNameByID[humanID] {
          return name
        }
        return humanID
      }

      // 2. DirectMic without speaker_index → "You" (self)
      if channel == 0, speakerIndex == nil {
        if let selfID = context?.selfHumanID,
          let selfName = context?.humanNameByID[selfID]
        {
          return selfName
        }
        return "You"
      }

      // 3. Unknown speaker — assign a stable number
      return labeler.unknownSpeakerLabel(for: self)
    }
  }

  // MARK: - Labeler State

  private var unknownSpeakerMap: [SegmentKey: Int] = [:]
  private var nextUnknownIndex = 1

  init() {}

  /// Initialize from existing segments (preserves existing labels).
  init(segments: [SegmentKey], context: SpeakerContext? = nil) {
    for segment in segments {
      if !segment.isKnownSpeaker(context: context) {
        _ = unknownSpeakerLabel(for: segment)
      }
    }
  }

  /// Get or create a label for a segment key.
  mutating func label(for key: SegmentKey, context: SpeakerContext? = nil) -> String {
    return key.label(context: context, labeler: &self)
  }

  /// Assign a consistent "Speaker N" label for an unknown speaker.
  mutating func unknownSpeakerLabel(for key: SegmentKey) -> String {
    if let existing = unknownSpeakerMap[key] {
      return "Speaker \(existing)"
    }
    let index = nextUnknownIndex
    unknownSpeakerMap[key] = index
    nextUnknownIndex += 1
    return "Speaker \(index)"
  }

  // MARK: - Label segments

  /// Label an array of transcript segments with speaker names.
  /// - Parameters:
  ///   - segments: Raw segments with channel/speaker info
  ///   - context: Known speakers and self identity
  /// - Returns: Segments with `speaker` field set to human-readable label
  mutating func labelSegments(
    _ segments: [RawTranscriptSegment],
    context: SpeakerContext? = nil
  ) -> [LabeledSegment] {
    return segments.map { segment in
      let key = SegmentKey(
        channel: segment.channel,
        speakerIndex: segment.speakerIndex,
        speakerHumanID: segment.speakerHumanID
      )
      let label = self.label(for: key, context: context)
      return LabeledSegment(
        speaker: label,
        text: segment.text,
        startMs: segment.startMs,
        endMs: segment.endMs,
        channel: segment.channel
      )
    }
  }
}

// MARK: - Data types

/// Raw transcript segment from the STT engine.
struct RawTranscriptSegment {
  let text: String
  let startMs: Double
  let endMs: Double
  let channel: Int
  var speakerIndex: Int?
  var speakerHumanID: String?
}

/// Labeled transcript segment with a human-readable speaker name.
struct LabeledSegment: Codable {
  let speaker: String
  let text: String
  let startMs: Double
  let endMs: Double
  let channel: Int
}

// MARK: - Integration helpers

extension SpeakerLabeler {
  /// Build a SpeakerContext from Wawa Note's calendar + contacts data.
  static func buildContext(
    calendarEventTitle: String?,
    participants: [AnarlogParticipant] = [],
    selfName: String? = nil
  ) -> SpeakerContext {
    var ctx = SpeakerContext()
    ctx.selfHumanID = selfName ?? "self"
    ctx.participants = participants

    if let selfName {
      ctx.humanNameByID["self"] = selfName
    }

    for p in participants {
      ctx.humanNameByID[p.name] = p.name
      if let title = p.jobTitle {
        ctx.humanNameByID[p.name] = "\(p.name) (\(title))"
      }
    }

    return ctx
  }

  /// Detect the "self" speaker from DirectMic channel (channel 0).
  /// The self speaker is the one speaking on channel 0 without a speaker_index.
  static func detectSelfSpeaker(from segments: [RawTranscriptSegment]) -> String? {
    // Simple heuristic: DirectMic with no speaker_index = self
    let hasDirectMic = segments.contains { $0.channel == 0 && $0.speakerIndex == nil }
    return hasDirectMic ? "You" : nil
  }
}

// MARK: - Overlap Detection

/// An overlap event where two or more speakers talk simultaneously.
struct SpeakerOverlap: Codable, Sendable {
  let startMs: Double
  let endMs: Double
  let speakers: [String]
  var durationMs: Double { endMs - startMs }

  var description: String {
    "\(speakers.joined(separator: " + ")) overlap for \(Int(durationMs))ms at \(Int(startMs))ms"
  }
}

extension SpeakerLabeler {
  /// Detect temporal overlaps between different speakers in labeled segments.
  /// Returns overlap events where 2+ speakers talk simultaneously.
  /// - Parameter segments: Labeled segments sorted by start time.
  /// - Parameter minOverlapMs: Minimum overlap duration to report (avoids noise).
  static func detectOverlaps(
    in segments: [LabeledSegment],
    minOverlapMs: Double = 200
  ) -> [SpeakerOverlap] {
    guard segments.count > 1 else { return [] }
    let sorted = segments.sorted { $0.startMs < $1.startMs }

    // Sweep line: process start/end events in time order.
    // Each event is (time: Double, isStart: Bool, segIndex: Int)
    var events: [(time: Double, isStart: Bool, segIndex: Int)] = []
    for (i, seg) in sorted.enumerated() {
      events.append((seg.startMs, true, i))
      events.append((seg.endMs, false, i))
    }
    events.sort { a, b in
      if a.time != b.time { return a.time < b.time }
      return a.isStart && !b.isStart
    }

    var overlaps: [SpeakerOverlap] = []
    var activeIndices = Set<Int>()
    var overlapStart: Double?
    var overlapSpeakers: Set<String> = []

    for event in events {
      if event.isStart {
        activeIndices.insert(event.segIndex)
      } else {
        activeIndices.remove(event.segIndex)
      }

      let speakers = Set(activeIndices.map { sorted[$0].speaker })

      if speakers.count >= 2 {
        if overlapStart == nil { overlapStart = event.time }
        overlapSpeakers = speakers
      } else if let start = overlapStart {
        let duration = event.time - start
        if duration >= minOverlapMs, !overlapSpeakers.isEmpty {
          overlaps.append(
            SpeakerOverlap(
              startMs: start, endMs: event.time,
              speakers: Array(overlapSpeakers).sorted()
            ))
        }
        overlapStart = nil
        overlapSpeakers = []
      }
    }

    return overlaps
  }
}
