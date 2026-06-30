import Foundation
import OSLog

/// LLM-based ASR transcript correction using JSON Patch (RFC 6902).
///
/// Ported from anarlog's `TranscriptPostprocessor` in `crates/transcript/src/postprocessor.rs`.
///
/// Flow:
/// 1. Extract words from transcript.json → [{id, text}]
/// 2. Send to LLM with system prompt asking for JSON Patch corrections
/// 3. Apply the patch to fix ASR mistakes
/// 4. Return corrected word list
///
/// The LLM is instructed to be conservative — only fix what's clearly wrong.
/// It never adds, removes, reorders, or changes word IDs.
struct TranscriptPatchService {
  private let logger = Logger(subsystem: "com.wawa.note", category: "TranscriptPatch")

  // MARK: - System Prompt (from anarlog's transcript-patch.system.md.jinja)

  static let systemPrompt = """
    # General Instructions

    You correct ASR transcript words and respond with an RFC 6902 JSON Patch.

    # Output Contract

    - Output exactly one JSON object with this shape: {"patch":[...]}.
    - `patch` must be a valid JSON Patch array.
    - If no correction is needed, return {"patch":[]}.
    - Do not wrap the JSON in markdown code fences.
    - Do not include any explanation.

    # Patch Rules

    - The input document shape is {"words":[{"id":"...","text":"..."}]}.
    - Only use `replace` operations.
    - Only modify `/words/<index>/text`.
    - Never add, remove, reorder, or move words.
    - Never change `/words/<index>/id`.
    - Preserve the original language unless the transcript clearly contains mixed-language speech.

    # Editing Guidance

    - Fix obvious ASR mistakes, punctuation, casing, spacing, and short filler artifacts only when the correction is highly likely.
    - Prefer conservative edits. If uncertain, leave the word unchanged.
    - Keep wording faithful to what was probably spoken. Do not summarize or paraphrase.
    """

  // MARK: - Types

  struct EditableWord: Codable {
    let id: String
    let text: String
  }

  struct EditableTranscriptDocument: Codable {
    let words: [EditableWord]
  }

  struct PatchEnvelope: Codable {
    let patch: [JSONPatchOperation]
  }

  struct JSONPatchOperation: Codable {
    let op: String  // "replace"
    let path: String  // "/words/0/text"
    let value: String  // corrected text
  }

  struct PatchResult {
    let correctedWords: [EditableWord]
    let corrections: [Correction]
    let rawResponse: String?
  }

  struct Correction {
    let wordID: String
    let original: String
    let corrected: String
  }

  // MARK: - Build request

  /// Build the user prompt from transcript words.
  func buildUserPrompt(words: [EditableWord]) throws -> String {
    let document = EditableTranscriptDocument(words: words)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let jsonData = try encoder.encode(document)
    let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

    return """
      Apply corrections to this transcript JSON document:

      \(jsonString)
      """
  }

  // MARK: - Parse response

  /// Parse the LLM response and apply the JSON Patch.
  func applyResponse(_ rawResponse: String, to originalWords: [EditableWord]) throws -> PatchResult
  {
    // Extract JSON from response (may be wrapped in markdown fences)
    let jsonString = extractJSON(from: rawResponse)

    guard let jsonData = jsonString.data(using: .utf8) else {
      throw PatchError.invalidResponse("Cannot encode response as UTF-8")
    }

    let envelope = try JSONDecoder().decode(PatchEnvelope.self, from: jsonData)

    // No corrections needed
    if envelope.patch.isEmpty {
      return PatchResult(correctedWords: originalWords, corrections: [], rawResponse: rawResponse)
    }

    // Apply patches
    var words = originalWords
    var corrections: [Correction] = []

    for operation in envelope.patch {
      guard operation.op == "replace" else { continue }

      // Parse index from path: "/words/0/text" → 0
      guard let index = parseWordIndex(from: operation.path) else {
        logger.warning("Cannot parse index from path: \(operation.path)")
        continue
      }

      guard index < words.count else {
        logger.warning("Index \(index) out of bounds (word count: \(words.count))")
        continue
      }

      let originalText = words[index].text
      let correctedText = operation.value

      if originalText != correctedText {
        words[index] = EditableWord(id: words[index].id, text: correctedText)
        corrections.append(
          Correction(
            wordID: words[index].id,
            original: originalText,
            corrected: correctedText
          ))
      }
    }

    logger.info(
      "Transcript patch: \(corrections.count) corrections applied out of \(originalWords.count) words"
    )
    return PatchResult(correctedWords: words, corrections: corrections, rawResponse: rawResponse)
  }

  // MARK: - Full pipeline

  /// Run the full transcript patch pipeline: build prompt → caller sends to LLM → apply response.
  /// Returns the user prompt string for the caller to send to their AI provider.
  func prepareRequest(from transcriptJSON: Data) throws -> (
    systemPrompt: String, userPrompt: String, wordCount: Int
  ) {
    let words = try JSONDecoder().decode([EditableWord].self, from: transcriptJSON)
    let userPrompt = try buildUserPrompt(words: words)
    return (Self.systemPrompt, userPrompt, words.count)
  }

  /// Apply the LLM response to the original transcript JSON data.
  func processResponse(_ rawResponse: String, originalTranscriptJSON: Data) throws -> (
    correctedJSON: Data, corrections: [Correction]
  ) {
    let words = try JSONDecoder().decode([EditableWord].self, from: originalTranscriptJSON)
    let result = try applyResponse(rawResponse, to: words)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let correctedData = try encoder.encode(result.correctedWords)

    return (correctedData, result.corrections)
  }

  // MARK: - Helpers

  private func extractJSON(from response: String) -> String {
    // Try to find JSON object in the response
    var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

    // Remove markdown code fences if present
    if text.hasPrefix("```json") {
      text = String(text.dropFirst(7))
    } else if text.hasPrefix("```") {
      text = String(text.dropFirst(3))
    }
    if text.hasSuffix("```") {
      text = String(text.dropLast(3))
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    return text
  }

  private func parseWordIndex(from path: String) -> Int? {
    // "/words/0/text" → 0
    // "/words/15/text" → 15
    let components = path.components(separatedBy: "/")
    guard components.count >= 3,
      components[1] == "words",
      let index = Int(components[2])
    else {
      return nil
    }
    return index
  }

  enum PatchError: Error, LocalizedError {
    case invalidResponse(String)

    var errorDescription: String? {
      switch self {
      case .invalidResponse(let msg): return "Invalid patch response: \(msg)"
      }
    }
  }
}

// MARK: - Transcript JSON ↔ EditableWords conversion

extension TranscriptPatchService {
  /// Convert the existing Wawa Note transcript.json segments to editable words.
  static func wordsFromTranscriptSegments(_ segments: [PatchTranscriptSegment]) -> [EditableWord] {
    var words: [EditableWord] = []
    for (segIdx, segment) in segments.enumerated() {
      let baseID = "seg\(segIdx)_\(segment.speaker.replacingOccurrences(of: " ", with: "_"))"
      // Split segment text into words
      let segmentWords = segment.text.components(separatedBy: " ")
      for (wordIdx, word) in segmentWords.enumerated() {
        // Skip empty words
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        words.append(EditableWord(id: "\(baseID)_w\(wordIdx)", text: trimmed))
      }
    }
    return words
  }

  /// Reassemble corrected words back into segment text.
  /// Preserves speaker assignments and timestamps from the original segments.
  static func applyCorrectedWordsToSegments(
    _ segments: [PatchTranscriptSegment],
    corrections: [TranscriptPatchService.Correction]
  ) -> [PatchTranscriptSegment] {
    // Build correction map: wordID → corrected text
    let correctionMap: [String: String] = Dictionary(
      uniqueKeysWithValues: corrections.map { ($0.wordID, $0.corrected) }
    )

    var wordIndex = 0
    return segments.map { segment in
      let segmentWords = segment.text.components(separatedBy: " ")
      let correctedWords = segmentWords.map { word -> String in
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return word }
        let wordID =
          "seg\(segments.firstIndex(where: { $0.speaker == segment.speaker }) ?? 0)_\(segment.speaker.replacingOccurrences(of: " ", with: "_"))_w\(wordIndex % segmentWords.count)"
        let corrected = correctionMap[wordID] ?? trimmed
        wordIndex += 1
        return corrected
      }
      return PatchTranscriptSegment(
        speaker: segment.speaker,
        text: correctedWords.joined(separator: " "),
        startMs: segment.startMs,
        endMs: segment.endMs
      )
    }
  }
}

/// Internal segment type for transcript patch operations.
/// Separate from the AnarlogImporter's type to avoid confusion.
struct PatchTranscriptSegment: Codable {
  let speaker: String
  let text: String
  let startMs: Double?
  let endMs: Double?
}
