import Foundation
import OSLog
import Speech
import WawaNoteCore

// MARK: - Progress

enum TranscriptionProgress: Sendable {
  case chunking(completed: Int, total: Int)
  case transcribing(chunk: Int, totalChunks: Int)
  case downloadingModel(String)
}

// MARK: - Engine Capabilities

/// Declares what a transcription engine can do.
/// Guideline: "Modele explicitamente os estados. Tenha uma interface comum."
struct TranscriptionCapabilities: Sendable {
  let supportsLive: Bool  // Buffer-based real-time
  let supportsFile: Bool  // URL-based batch
  let isOnDevice: Bool  // Guaranteed local (no network)
  let maxDuration: TimeInterval  // Max audio duration (seconds)
  let supportedLocales: [Locale]
  let hasModelDownload: Bool  // Needs asset download step
}

// MARK: - Live Transcription Types

/// A single live transcription result — can be volatile or final.
struct LiveTranscriptionResult: Sendable {
  let text: String
  let segments: [TranscriptSegment]
  let isFinal: Bool
  let confidence: Double?
}

/// Stream of live transcription results.
typealias LiveTranscriptionStream = AsyncThrowingStream<LiveTranscriptionResult, Error>

// MARK: - Engine Protocol

protocol TranscriptionEngine: Sendable {
  var id: String { get }
  var displayName: String { get }
  var isCancelled: Bool { get }
  var capabilities: TranscriptionCapabilities { get }

  /// Transcribe a pre-recorded audio file.
  /// - Parameter meetingId: the KnowledgeItem ID this transcript belongs to.
  func transcribeFile(_ audioFileURL: URL, meetingId: UUID) async throws -> Transcript

  /// Transcribe a live audio stream (buffer-based).
  /// Returns an async stream of volatile + final results.
  /// Guideline: "Diferencie resultado volátil de resultado finalizado."
  func transcribeLive(from audioFileURL: URL) -> LiveTranscriptionStream

  /// Cancel an in-progress transcription.
  func cancel()

  /// Check engine availability (model, permission, locale).
  func checkAvailability() -> LocalTranscriptionAvailability

  /// Ensure prerequisites are met (model download, permission, etc).
  /// Called before transcription starts.
  func prepareIfNeeded() async throws

  /// Progress callback — fired during chunking and per-chunk transcription.
  var onProgress: ((TranscriptionProgress) -> Void)? { get set }

  /// Checkpoint callback — fired after each successfully transcribed chunk.
  /// Engine calls this with the cumulative transcript so far and the 1-based
  /// index of the last completed chunk.
  var onCheckpoint: ((Transcript, Int) -> Void)? { get set }

  /// Resume offset — set before transcribeFile() to skip already-completed
  /// chunks from a previous attempt. 0-based: value N means chunks 0..<N
  /// are already done, start from chunk N.
  var resumeFromChunk: Int { get set }

  /// Text of the last checkpoint segment(s), used to seed previousText on
  /// resume so deduplicateStart correctly removes the chunk overlap at the
  /// resume boundary. Set before transcribeFile() alongside resumeFromChunk.
  var resumePreviousText: String { get set }

  /// Called by the orchestrator after transcribeFile() completes successfully
  /// to signal no more checkpoints will be emitted. The engine MUST nil out
  /// its onCheckpoint reference to prevent late checkpoints from racing with
  /// the final transcript write.
  mutating func finalize()

  /// BCP-47 language hint sent to the Whisper API as the `language` parameter.
  /// Prevents auto-detection from picking the wrong language on silent/noisy audio.
  /// Set before transcribeFile(); nil means auto-detect (default).
  var languageHint: String? { get set }
}

// MARK: - Default implementations

extension TranscriptionEngine {
  /// Default: not all engines support live transcription.
  func transcribeLive(from audioFileURL: URL) -> LiveTranscriptionStream {
    LiveTranscriptionStream { continuation in
      continuation.finish()
    }
  }

  func prepareIfNeeded() async throws {
    let availability = checkAvailability()
    switch availability {
    case .available:
      return
    case .permissionDenied:
      throw TranscriptionError.notAuthorized
    case .hardwareUnsupported:
      throw TranscriptionError.onDeviceUnavailable
    case .modelMissing(let locale):
      throw TranscriptionError.modelNotInstalled(locale.identifier)
    case .localeUnsupported:
      throw TranscriptionError.noSupportedLocale
    case .failed(let message):
      throw TranscriptionError.recognitionFailed(message)
    }
  }
}

// MARK: - Default implementations for progress, checkpoint, resume

extension TranscriptionEngine {
  var onProgress: ((TranscriptionProgress) -> Void)? {
    get { nil }
    set { /* no-op for engines that don't report progress */  }
  }

  var onCheckpoint: ((Transcript, Int) -> Void)? {
    get { nil }
    set { /* no-op for engines without checkpoint support */  }
  }

  var resumeFromChunk: Int {
    get { 0 }
    set { /* no-op for engines without resume support */  }
  }

  var resumePreviousText: String {
    get { "" }
    set { /* no-op for engines without resume support */  }
  }

  var languageHint: String? {
    get { nil }
    set { /* no-op for engines that don't need language hints */  }
  }

  mutating func finalize() {
    onCheckpoint = nil
    onProgress = nil
  }
}

// MARK: - Transcription locale provider

/// Single source of truth for available transcription locales.
/// Queries the device at runtime so the UI only shows languages with
/// downloaded on-device speech models (SFSpeechRecognizer.isAvailable).
enum TranscriptionLocaleProvider {

  /// All locales the user can select, filtered to only those with
  /// downloaded on-device speech models. Falls back to the full
  /// configured list when no models are installed yet (iOS downloads
  /// them automatically when the device is on Wi-Fi).
  static var availableLocales: [(id: String, name: String)] {
    let live = liveLocales()
    if live.isEmpty {
      return fallbackLocales
    }
    return live
  }

  /// Best-guess locale for initial picker selection.
  /// Uses the device language if its speech model is available,
  /// otherwise falls back to "en-US", then the first available locale.
  static var bestGuessLocale: String {
    let deviceLang = Locale.current.language.languageCode?.identifier ?? "en"
    let available = availableLocales.map(\.id)
    // Try exact device language match
    if let match = available.first(where: {
      $0.hasPrefix(deviceLang)
    }) {
      return match
    }
    // Fall back to en-US
    if available.contains("en-US") { return "en-US" }
    // Last resort: first available
    return available.first ?? "en-US"
  }

  /// Human-readable name for a BCP-47 locale identifier.
  static func displayName(_ id: String) -> String {
    let locale = Locale(identifier: id)
    let langName = locale.localizedString(forLanguageCode: String(id.prefix(2))) ?? id
    // Append region when available
    if let region = locale.region?.identifier {
      let regionName = locale.localizedString(forRegionCode: region)
      if let regionName, !regionName.isEmpty {
        return "\(langName) (\(regionName))"
      }
    }
    return langName
  }

  // MARK: Private

  private static let fallbackLocales: [(id: String, name: String)] = {
    let ids = [
      "pt-BR", "pt-PT", "en-US", "es-ES",
      "fr-FR", "de-DE", "it-IT", "ja-JP", "zh-CN",
    ]
    return ids.map { ($0, displayName($0)) }
  }()

  private static func liveLocales() -> [(id: String, name: String)] {
    let configured = Set(fallbackLocales.map(\.id))
    // Show all system-supported locales — do NOT filter by isAvailable.
    // If the model hasn't been downloaded yet, the engine returns a clear
    // .modelMissing error telling the user to connect to Wi-Fi. Silent
    // fallback to a different language is far worse than a clear error.
    return SFSpeechRecognizer.supportedLocales()
      .filter { configured.contains($0.identifier) }
      .map { ($0.identifier, displayName($0.identifier)) }
      .sorted { $0.1 < $1.1 }
  }
}

// MARK: - TranscriptValidator

/// Post-processing validation for transcript segments.
///
/// Filters out segments that match known hallucination patterns:
/// - Non-English text when English is expected (CJK characters, etc.)
/// - Repeated text loops (same text appearing >3 times consecutively)
/// - Low-confidence segments (when confidence data is available)
///
/// Applied after transcription, before saving transcript.json.
enum TranscriptValidator {
  private static let logger = Logger(
    subsystem: "com.wawa.note", category: "TranscriptValidator")

  struct ValidationResult {
    let kept: [TranscriptSegment]
    let discarded: [TranscriptSegment]
    let warnings: [String]
  }

  /// Validate transcript segments against hallucination heuristics.
  /// - Parameters:
  ///   - segments: Raw segments from the transcription engine
  ///   - expectedLanguage: BCP-47 or plain name (e.g. "en", "english")
  /// - Returns: ValidationResult with kept/discarded segments and warnings
  static func validate(
    _ segments: [TranscriptSegment], expectedLanguage: String
  ) -> ValidationResult {
    guard !segments.isEmpty else {
      return ValidationResult(kept: [], discarded: [], warnings: [])
    }

    var kept: [TranscriptSegment] = []
    var discarded: [TranscriptSegment] = []
    var warnings: [String] = []

    let isEnglishExpected = expectedLanguage.lowercased().hasPrefix("en")

    // Build a run-length tracker for repetition detection
    var repeatCount = 0
    var lastText = ""

    for segment in segments {
      let text = segment.text.trimmingCharacters(in: .whitespaces)

      // Rule 1: Skip empty segments
      guard !text.isEmpty else {
        discarded.append(segment)
        continue
      }

      // Rule 2: CJK character detection for English-language transcripts
      // Whisper sometimes hallucinates Japanese/Chinese text during silence
      if isEnglishExpected && containsCJK(text) {
        discarded.append(segment)
        if warnings.count < 5 {
          warnings.append(
            "Discarded CJK segment: \"\(text.prefix(60))...\"")
        }
        continue
      }

      // Rule 3: Repetition loop detection
      // Same text appearing >3 times consecutively is a hallucination pattern
      if text == lastText {
        repeatCount += 1
        if repeatCount > 3 {
          discarded.append(segment)
          continue
        }
      } else {
        repeatCount = 1
        lastText = text
      }

      // Rule 4: Low confidence (only applies when confidence data is available)
      if let confidence = segment.confidence, confidence < 0.3 {
        discarded.append(segment)
        if warnings.count < 5 {
          warnings.append(
            "Discarded low-confidence segment (confidence: \(String(format: "%.2f", confidence)))")
        }
        continue
      }

      kept.append(segment)
    }

    if !discarded.isEmpty {
      logger.warning(
        "TranscriptValidator: discarded \(discarded.count)/\(segments.count) segments (\(warnings.count) warning types)"
      )
      for warning in warnings {
        logger.warning("  \(warning)")
      }
    }

    return ValidationResult(kept: kept, discarded: discarded, warnings: warnings)
  }

  // MARK: - Helpers

  /// Check if text contains CJK (Chinese/Japanese/Korean) characters.
  private static func containsCJK(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x4E00...0x9FFF,  // CJK Unified Ideographs
        0x3400...0x4DBF,  // CJK Extension A
        0x3040...0x309F,  // Hiragana
        0x30A0...0x30FF,  // Katakana
        0xAC00...0xD7AF,  // Hangul Syllables
        0x1100...0x11FF,  // Hangul Jamo
        0x3000...0x303F,  // CJK Symbols
        0xFF00...0xFFEF,  // Fullwidth Forms
        0x3100...0x312F,  // Bopomofo
        0x3300...0x33FF,  // CJK Compatibility
        0xF900...0xFAFF:  // CJK Compatibility Ideographs
        return true
      default:
        break
      }
    }
    return false
  }
}
