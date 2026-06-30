import Foundation
import SwiftData

enum ItemStatus: String, Codable, CaseIterable {
  case draft
  case recording
  /// Audio segments written. Concatenation to audio.m4a is in progress.
  case preparingAudio
  /// audio.m4a is ready. Item is in the processing queue, waiting for its turn.
  case queuedForTranscription
  /// Legacy: used for items recorded before explicit queue statuses were added.
  case recorded
  case transcribing
  case transcribed
  /// Extraction/transcription is complete but user hasn't reviewed yet.
  /// Pipeline pauses here — user must approve before analysis proceeds.
  case pendingReview
  case analyzing
  case analyzed
  case failed
  case archived

  /// State machine: valid transitions for each status.
  /// Transitions not listed here are illegal and indicate a bug.
  ///
  /// Flow:
  ///   draft → recording → preparingAudio → queuedForTranscription → transcribing → transcribed
  ///                                                                                     ↓
  ///                                                                             pendingReview → analyzing → analyzed
  ///   Any active state → failed (terminal)
  ///   Any state → archived (terminal, manual only)
  var validNextStatuses: Set<ItemStatus> {
    switch self {
    case .draft:
      [.recording, .analyzing]
    case .recording:
      [.preparingAudio, .recorded, .failed]
    case .preparingAudio:
      [.queuedForTranscription, .failed]
    case .queuedForTranscription:
      [.transcribing, .failed]
    case .recorded:
      [.transcribing, .queuedForTranscription, .failed]
    case .transcribing:
      [.transcribed, .failed]
    case .transcribed:
      [.pendingReview, .analyzing, .failed]
    case .pendingReview:
      [.analyzing, .recorded, .failed]
    case .analyzing:
      [.analyzed, .failed]
    case .analyzed:
      [.failed]  // re-analysis allowed
    case .failed:
      [.queuedForTranscription, .recorded]  // retry
    case .archived:
      []  // terminal
    }
  }

  /// Returns true if transitioning to `next` is allowed by the state machine.
  func canTransition(to next: ItemStatus) -> Bool {
    validNextStatuses.contains(next)
  }

  /// Human-readable label for UI badges and status bars.
  var label: String {
    switch self {
    case .draft: return "Draft"
    case .recording: return "Recording"
    case .preparingAudio: return "Preparing audio"
    case .queuedForTranscription: return "Queued"
    case .recorded: return "Recorded"
    case .transcribing: return "Transcribing"
    case .transcribed: return "Transcribed"
    case .pendingReview: return "Needs review"
    case .analyzing: return "Analyzing"
    case .analyzed: return "Analyzed"
    case .failed: return "Failed"
    case .archived: return "Archived"
    }
  }

  /// SF Symbol for the status badge.
  var icon: String {
    switch self {
    case .draft: return "doc"
    case .recording: return "recordingtape"
    case .preparingAudio: return "gearshape"
    case .queuedForTranscription: return "hourglass"
    case .recorded: return "circle.dotted"
    case .transcribing: return "text.alignleft"
    case .transcribed: return "text.alignleft"
    case .pendingReview: return "eye"
    case .analyzing: return "sparkles"
    case .analyzed: return "sparkles.rectangle.stack"
    case .failed: return "exclamationmark.triangle"
    case .archived: return "archivebox"
    }
  }

  /// Semantic tone for color-coding badges.
  enum StatusTone { case neutral, active, success, warning, error }
  var tone: StatusTone {
    switch self {
    case .draft, .recorded: return .neutral
    case .recording, .preparingAudio, .queuedForTranscription, .transcribing, .analyzing:
      return .active
    case .transcribed, .analyzed: return .success
    case .pendingReview, .archived: return .warning
    case .failed: return .error
    }
  }
}

enum KnowledgeItemType: String, Codable, CaseIterable, Hashable {
  case audio = "audio"
  case note
  case journalEntry
  case webBookmark
  case image
}

// MARK: - Display helpers

extension KnowledgeItemType {
  var icon: String {
    switch self {
    case .audio: "recordingtape"
    case .note: "note.text"
    case .journalEntry: "book"
    case .webBookmark: "bookmark"
    case .image: "photo"
    }
  }

  var label: String { rawValue.capitalized }
}

@Model
final class KnowledgeItem {
  @Attribute(.unique) var id: UUID
  var typeRaw: String
  var title: String
  /// Preserved original title (filename, recording date, etc.) before AI rename.
  var originalTitle: String?
  var createdAt: Date
  var updatedAt: Date
  var statusRaw: String
  // [String] is NOT supported as a direct SwiftData attribute — CoreData
  // cannot materialize "Array<String>" (crash: "Could not materialize
  // Objective-C class named 'Array'"). Store as JSON string instead.
  private var _tagsJSON: String = "[]"
  @Transient
  var tags: [String] {
    get {
      guard let data = _tagsJSON.data(using: .utf8),
        let result = try? JSONDecoder().decode([String].self, from: data)
      else {
        return []
      }
      return result
    }
    set {
      if let data = try? JSONEncoder().encode(newValue),
        let json = String(data: data, encoding: .utf8)
      {
        _tagsJSON = json
      } else {
        _tagsJSON = "[]"
      }
    }
  }

  // Cross-type queryable columns
  var durationSeconds: Double?
  var languageCode: String?
  var folderID: UUID?
  var projectID: UUID?
  var isFlagged: Bool

  // Content body (Markdown for notes, journal entries)
  var bodyText: String?

  // Inbox — non-nil means item is waiting to be processed
  var inboxDate: Date?

  // Context columns
  var contextCalendarEventTitle: String?
  var contextAudioRoute: String?
  var contextPlaceName: String?
  var contextLatitude: Double?
  var contextLongitude: Double?
  var contextFocusActive: Bool?
  var contextMotionActivity: String?
  var contextBatteryLevel: Double?

  // Legacy meeting fields
  var audioFileRelativePath: String?
  /// Sample rate of the captured audio (e.g., 44100 for built-in mic, 8000 for Bluetooth HFP).
  var audioSampleRate: Double?
  /// Number of audio channels (1 = mono).
  var audioChannelCount: Int?
  /// Input port type used for capture (e.g., "builtInMic", "bluetoothHFP", "usbAudio").
  var audioInputPortType: String?
  /// Human-readable input port name (e.g., "iPhone", "AirPods Pro").
  var audioInputPortName: String?
  var imageFileRelativePath: String?
  var imagePageCount: Int?
  var transcriptionEngineId: String?
  var analysisProviderId: String?
  var calendarEventIdentifier: String?
  var scheduledDate: Date?
  var isImported: Bool = false
  var importSourceURL: String?
  // Field authority
  var fieldProvenanceJSON: String?
  // Anarlog compatibility: preserves original YAML frontmatter for round-trip fidelity
  var anarlogFrontmatterJSON: String?
  var needsProjectReprocessing: Bool = false
  var projectReprocessContext: String?

  var type: KnowledgeItemType {
    get {
      // Migration: "meeting" was renamed to "audio"
      if typeRaw == "meeting" { return .audio }
      return KnowledgeItemType(rawValue: typeRaw) ?? .audio
    }
    set { typeRaw = newValue.rawValue }
  }

  var status: ItemStatus {
    get { ItemStatus(rawValue: statusRaw) ?? .draft }
    set { statusRaw = newValue.rawValue }
  }

  /// Transition to a new status with validation. Logs a warning if the
  /// transition is illegal per the state machine, but still allows it
  /// for backwards compatibility. Prefer this over direct `status = ...`.
  func transitionStatus(to next: ItemStatus, reason: String) {
    let current = self.status
    guard current.canTransition(to: next) else {
      AppLog.warn(
        "status",
        "⚠️ Illegal state transition: \(current.rawValue) → \(next.rawValue) — \(reason). Fix the call site."
      )
      self.status = next
      return
    }
    self.status = next
  }

  init(
    id: UUID = UUID(),
    type: KnowledgeItemType = .audio,
    title: String = "",
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    status: ItemStatus = .draft,
    tags: [String] = [],
    folderID: UUID? = nil,
    isFlagged: Bool = false,
    bodyText: String? = nil,
    durationSeconds: Double? = nil,
    languageCode: String? = nil,
    inboxDate: Date? = Date()
  ) {
    self.id = id
    self.typeRaw = type.rawValue
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.statusRaw = status.rawValue
    if let data = try? JSONEncoder().encode(tags),
      let json = String(data: data, encoding: .utf8)
    {
      self._tagsJSON = json
    }
    self.folderID = folderID
    self.projectID = nil
    self.isFlagged = isFlagged
    self.bodyText = bodyText
    self.durationSeconds = durationSeconds
    self.languageCode = languageCode
    self.inboxDate = inboxDate
    self.fieldProvenanceJSON = nil
    self.needsProjectReprocessing = false
    self.projectReprocessContext = nil
  }
}

// MARK: - KnowledgeItem + FieldProvidence

extension KnowledgeItem: FieldProvidence {
  var provenance: FieldProvenance {
    get { FieldProvenance.decode(from: fieldProvenanceJSON) }
    set { fieldProvenanceJSON = newValue.encode() }
  }

  func writeProvenance() {
    fieldProvenanceJSON = provenance.encode()
  }
}

// MARK: - Tag normalization

/// Normalizes and merges tags to keep the tag vocabulary consistent.
/// All tags are lowercased, trimmed, deduplicated, and sorted.
enum TagNormalizer {
  /// Normalize a single tag: lowercase, trim whitespace.
  static func normalize(_ tag: String) -> String {
    tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Normalize and deduplicate an array of tags.
  static func normalize(_ tags: [String]) -> [String] {
    let cleaned = tags.map { normalize($0) }.filter { !$0.isEmpty }
    var seen = Set<String>()
    return cleaned.filter { seen.insert($0).inserted }.sorted()
  }

  /// Merge AI-suggested tags with existing user/in-app tags.
  /// Existing tags are preserved; suggested tags are appended (normalized, deduped).
  static func merge(existing: [String], suggested: [String]) -> [String] {
    let normalized = normalize(existing + suggested)
    return normalized
  }

  /// Append a single tag to an existing array, normalizing and deduplicating.
  /// Use this instead of raw `.append()` to keep tags consistent.
  static func append(tag: String, to existing: [String]) -> [String] {
    merge(existing: existing, suggested: [tag])
  }

  /// Replace tags matching a prefix with a new tag (e.g. mood/ tags).
  /// Non-matching tags are preserved as-is.
  static func replace(prefix: String, with tag: String, in tags: [String]) -> [String] {
    let kept = tags.filter { !$0.hasPrefix(prefix) }
    return merge(existing: kept, suggested: [tag])
  }
}
