import Foundation
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
