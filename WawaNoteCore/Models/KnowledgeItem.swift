import Foundation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.wawa-note.core", category: "models")

public enum ItemStatus: String, Codable, CaseIterable {

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

  public var validNextStatuses: Set<ItemStatus> {

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

  public func canTransition(to next: ItemStatus) -> Bool {

    validNextStatuses.contains(next)

  }

  /// Human-readable label for UI badges and status bars.

  public var label: String {

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

  public var icon: String {

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

  public enum StatusTone { case neutral, active, success, warning, error }

  public var tone: StatusTone {

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

public enum KnowledgeItemType: String, Codable, Sendable, CaseIterable, Hashable {

  case audio = "audio"

  case note

  case journalEntry

  case webBookmark

  case image

}

// MARK: - Display helpers

extension KnowledgeItemType {

  public var icon: String {

    switch self {

    case .audio: "recordingtape"

    case .note: "note.text"

    case .journalEntry: "book"

    case .webBookmark: "bookmark"

    case .image: "photo"

    }

  }

  public var label: String { rawValue.capitalized }

}

@Model

public final class KnowledgeItem {

  @Attribute(.unique) public var id: UUID

  public var typeRaw: String

  public var title: String

  /// Preserved original title (filename, recording date, etc.) before AI rename.

  public var originalTitle: String?

  public var createdAt: Date

  public var updatedAt: Date

  public var statusRaw: String

  // [String] is NOT supported as a direct SwiftData attribute — CoreData

  // cannot materialize "Array<String>" (crash: "Could not materialize

  // Objective-C class named 'Array'"). Store as JSON string instead.

  private var _tagsJSON: String = "[]"

  @Transient

  public var tags: [String] {

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

  public var durationSeconds: Double?

  public var languageCode: String?

  public var folderID: UUID?

  public var projectID: UUID?

  public var isFlagged: Bool

  // Content body (Markdown for notes, journal entries)

  public var bodyText: String?

  // Inbox — non-nil means item is waiting to be processed

  public var inboxDate: Date?

  // Context columns

  public var contextCalendarEventTitle: String?

  public var contextAudioRoute: String?

  public var contextPlaceName: String?

  public var contextLatitude: Double?

  public var contextLongitude: Double?

  public var contextFocusActive: Bool?

  public var contextMotionActivity: String?

  public var contextBatteryLevel: Double?

  // Legacy meeting fields

  public var audioFileRelativePath: String?

  /// Sample rate of the captured audio (e.g., 44100 for built-in mic, 8000 for Bluetooth HFP).

  public var audioSampleRate: Double?

  /// Number of audio channels (1 = mono).

  public var audioChannelCount: Int?

  /// Input port type used for capture (e.g., "builtInMic", "bluetoothHFP", "usbAudio").

  public var audioInputPortType: String?

  /// Human-readable input port name (e.g., "iPhone", "AirPods Pro").

  public var audioInputPortName: String?

  public var imageFileRelativePath: String?

  public var imagePageCount: Int?

  public var transcriptionEngineId: String?

  public var analysisProviderId: String?

  public var calendarEventIdentifier: String?

  public var scheduledDate: Date?

  public var isImported: Bool = false

  public var importSourceURL: String?

  /// Bundle ID of the source app (e.g., "net.whatsapp.WhatsApp")

  public var importSourceApp: String?

  /// true if the extension timed out before completing the import

  public var isIncomplete: Bool = false

  /// Error message if the import failed in the extension but the item was still created

  public var importError: String?

  // Field authority

  public var fieldProvenanceJSON: String?

  // Anarlog compatibility: preserves original YAML frontmatter for round-trip fidelity

  public var anarlogFrontmatterJSON: String?

  public var needsProjectReprocessing: Bool = false

  public var projectReprocessContext: String?

  public var type: KnowledgeItemType {

    get {

      // Migration: "meeting" was renamed to "audio"

      if typeRaw == "meeting" { return .audio }

      return KnowledgeItemType(rawValue: typeRaw) ?? .audio

    }

    set { typeRaw = newValue.rawValue }

  }

  public var status: ItemStatus {

    get { ItemStatus(rawValue: statusRaw) ?? .draft }

    set { statusRaw = newValue.rawValue }

  }

  /// Transition to a new status with validation. Logs a warning if the

  /// transition is illegal per the state machine, but still allows it

  /// for backwards compatibility. Prefer this over direct `status = ...`.

  public func transitionStatus(to next: ItemStatus, reason: String) {
    let current = self.status

    guard current.canTransition(to: next) else {

      log.warning(

        "⚠️ Illegal state transition: \(current.rawValue) → \(next.rawValue) — \(reason). Fix the call site."

      )

      self.status = next

      return

    }

    self.status = next

  }

  public init(

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

    self.importSourceApp = nil

    self.isIncomplete = false

    self.importError = nil

  }

}

// MARK: - KnowledgeItem + FieldProvidence

extension KnowledgeItem: FieldProvidence {

  public var provenance: FieldProvenance {

    get { FieldProvenance.decode(from: fieldProvenanceJSON) }

    set { fieldProvenanceJSON = newValue.encode() }

  }

  public func writeProvenance() {

    fieldProvenanceJSON = provenance.encode()

  }

}

// MARK: - Tag normalization

/// Normalizes and merges tags to keep the tag vocabulary consistent.

/// All tags are lowercased, trimmed, deduplicated, and sorted.

public enum TagNormalizer {

  /// Normalize a single tag: lowercase, trim whitespace.

  public static func normalize(_ tag: String) -> String {

    tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

  }

  /// Normalize and deduplicate an array of tags.

  public static func normalize(_ tags: [String]) -> [String] {

    let cleaned = tags.map { normalize($0) }.filter { !$0.isEmpty }

    var seen = Set<String>()

    return cleaned.filter { seen.insert($0).inserted }.sorted()

  }

  /// Merge AI-suggested tags with existing user/in-app tags.

  /// Existing tags are preserved; suggested tags are appended (normalized, deduped).

  public static func merge(existing: [String], suggested: [String]) -> [String] {

    let normalized = normalize(existing + suggested)

    return normalized

  }

  /// Append a single tag to an existing array, normalizing and deduplicating.

  /// Use this instead of raw `.append()` to keep tags consistent.

  public static func append(tag: String, to existing: [String]) -> [String] {

    merge(existing: existing, suggested: [tag])

  }

  /// Replace tags matching a prefix with a new tag (e.g. mood/ tags).

  /// Non-matching tags are preserved as-is.

  public static func replace(prefix: String, with tag: String, in tags: [String]) -> [String] {

    let kept = tags.filter { !$0.hasPrefix(prefix) }

    return merge(existing: kept, suggested: [tag])

  }

}
