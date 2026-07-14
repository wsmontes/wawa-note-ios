import Foundation
import SwiftData
import WawaNoteCore

// Related JIRA: KAN-XX

// MARK: - Content Processor Protocol

/// Extracts text from a KnowledgeItem. Each content type (audio, image,
/// text) has its own processor conforming to this protocol.
@MainActor
protocol ContentProcessor {
  /// Extracts text from the item. MUST set item.status = .failed and
  /// item.lastErrorRaw on failure before returning nil.
  /// - Returns: extracted text, or nil if extraction failed.
  func extract(from item: KnowledgeItem, context: ModelContext) async -> String?
}

// MARK: - Extraction Error

/// Structured error codes for every failure path in content extraction.
/// Each case carries a user-visible message set on item.lastErrorRaw.
enum ExtractionError: Error, LocalizedError {
  case audioFileNotFound
  case audioTooSmall
  case audioTooShort
  case audioTooLong(Double)
  case noEngineAvailable
  case speechPermissionDenied
  case modelNotInstalled(String)
  case recognitionTimedOut
  case noInternet
  case remoteAuthFailed
  case remoteFileTooLarge
  case remoteRateLimited
  case remoteServerError
  case retriesExhausted(Int, String)
  case engineError(String)
  case noSpeechDetected
  case imageUnreadable
  case imageNoContent
  case ocrFailed
  case textEmpty
  case bookmarkFetchFailed
  case taskCancelled

  var errorDescription: String? {
    switch self {
    case .audioFileNotFound:
      return "Audio file not found. It may have been moved or deleted."
    case .audioTooSmall:
      return "Audio file is too small (less than 4KB). Try recording again."
    case .audioTooShort:
      return "Audio is less than 1 second. Record at least a few seconds of speech."
    case .audioTooLong(let d):
      return "Recording is \(Int(d))s — exceeds 2-hour maximum. Split into shorter segments."
    case .noEngineAvailable:
      return "No transcription engine available. Check Settings → AI Services."
    case .speechPermissionDenied:
      return
        "Speech recognition permission denied. Enable in Settings → Privacy → Speech Recognition."
    case .modelNotInstalled(let locale):
      return "On-device speech model for \(locale) not installed. Connect to Wi-Fi to download."
    case .recognitionTimedOut:
      return "On-device recognition timed out. Try a shorter recording or switch to Whisper API."
    case .noInternet:
      return "No internet connection. Whisper API requires network access."
    case .remoteAuthFailed:
      return "Whisper API authentication failed. Check your API key in Settings → AI Services."
    case .remoteFileTooLarge:
      return "Audio too large for Whisper API (max 25 MB). Try a shorter recording."
    case .remoteRateLimited:
      return "Whisper API rate limited. Wait a few minutes and try again."
    case .remoteServerError:
      return "Whisper API server error. The service may be temporarily unavailable."
    case .retriesExhausted(let n, let msg):
      return "Transcription failed after \(n) attempts. Last error: \(msg)"
    case .engineError(let detail):
      return "Transcription engine error: \(detail)"
    case .noSpeechDetected:
      return "No speech detected in the audio. Try recording in a quieter environment."
    case .imageUnreadable:
      return "Image file could not be read. It may be corrupted."
    case .imageNoContent:
      return "No text or visual content could be extracted from this image."
    case .ocrFailed:
      return "Text recognition failed. Try a clearer photo with better lighting."
    case .textEmpty:
      return "No text content found in this item."
    case .bookmarkFetchFailed:
      return "Could not fetch content from the bookmark URL."
    case .taskCancelled:
      return "Processing was cancelled."
    }
  }
}

// MARK: - Source Context

/// Describes where an item came from so the analysis prompt can adapt.
struct SourceContext: Sendable {
  enum SourceType: String, Sendable {
    case recording
    case import_
    case scan
    case note
  }

  let sourceType: SourceType
  let metadata: [String: String]

  static func from(_ item: KnowledgeItem) -> SourceContext {
    let sourceType: SourceType
    var metadata: [String: String] = [:]

    if item.audioFileRelativePath != nil {
      sourceType = .recording
      if let dur = item.durationSeconds { metadata["duration"] = formatDuration(dur) }
      if let lang = item.languageCode { metadata["language"] = lang }
    } else if item.imageFileRelativePath != nil {
      sourceType = .scan
      if let pages = item.imagePageCount { metadata["pageCount"] = String(pages) }
    } else if item.isImported {
      sourceType = .import_
      if let source = item.importSourceURL {
        metadata["filename"] = URL(string: source)?.lastPathComponent ?? source
      }
    } else {
      sourceType = .note
    }

    metadata["createdAt"] = item.createdAt.formatted(date: .complete, time: .shortened)
    if !item.tags.isEmpty { metadata["tags"] = item.tags.joined(separator: ", ") }

    return SourceContext(sourceType: sourceType, metadata: metadata)
  }

  func analysisSystemPrompt() -> String {
    switch sourceType {
    case .recording:
      return
        "You are an audio content analyst. Extract decisions, action items with owners, risks, open questions, important dates, mentioned people/systems/organizations, and a topic timeline. Return only valid JSON."
    case .import_:
      return
        "You are a document analyst. Analyze this imported file. Identify its structure, key points, decisions if any, action items, risks, mentioned entities, and dates. Consider the filename and metadata for context. Return only valid JSON."
    case .scan:
      return
        "You are a visual content analyst. Analyze this image description (which may include OCR text and/or an AI-generated visual description). Identify what is depicted, key objects, text content, context, and any action items or insights. Note this is NOT a meeting transcript — focus on visual content. Return only valid JSON."
    case .note:
      return
        "You are a knowledge analyst. Analyze this note. Extract key themes, questions being explored, references to other topics, action items if any, and people/systems mentioned. Return only valid JSON."
    }
  }

  func userPromptPrefix() -> String {
    var lines: [String] = []
    switch sourceType {
    case .recording:
      lines.append("The following is an audio transcript.")
      if let dur = metadata["duration"] { lines.append("Duration: \(dur)") }
      if let lang = metadata["language"] { lines.append("Language: \(lang)") }
    case .import_:
      lines.append("The following is the content of an imported file.")
      if let fn = metadata["filename"] { lines.append("Filename: \(fn)") }
    case .scan:
      lines.append(
        "The following describes an image (may include OCR text and/or visual scene description).")
      if let pages = metadata["pageCount"] { lines.append("Pages: \(pages)") }
    case .note:
      lines.append("The following is a user note.")
    }
    if let tags = metadata["tags"], !tags.isEmpty { lines.append("Tags: \(tags)") }
    if let createdAt = metadata["createdAt"] { lines.append("Created: \(createdAt)") }
    return lines.joined(separator: "\n") + "\n\n"
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return "\(m)m \(s)s"
  }
}
