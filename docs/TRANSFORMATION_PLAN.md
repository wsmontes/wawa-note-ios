Now I have a thorough understanding of the codebase. Let me synthesize everything into the transformation plan. I have examined all existing models (MeetingModel, MeetingAnalysis, TranscriptSegment, AIProviderConfigModel, ChatConversationModel, ChatMessageModel), all services (AIConfigService, AnalysisService, AudioImportService, FileArtifactStore, CalendarSyncService), all providers (AIProvider protocol, OpenAICompatibleProvider, ProviderRouter), all UI (ContentView with tabs, HomeView, MeetingsListView, MeetingDetailView, RecordView, RecordingCoordinator), the transcription layer (TranscriptionEngine protocol, AppleSpeechTranscriptionEngine, RemoteTranscriptionEngine), the export layer (MarkdownExporter, JSONExporter), the project configuration (project.yml targeting iOS 17.0, Swift 6.0), and the existing architecture docs.

Here is the comprehensive transformation plan.

---

# Wawa Note Transformation Plan: Meeting Recorder to Knowledge Workspace

**Version:** 1.0
**Date:** 2026-05-26
**Status:** Planning

---

## 1. Executive Summary

This document defines the transformation of wawa-note from a single-purpose meeting recorder into an open-source, local-first knowledge workspace for iOS.

**What changes:** The app's identity, data model, user experience, and extensibility architecture all shift. `MeetingModel` becomes a polymorphic `KnowledgeItem`. A fixed meeting pipeline becomes a configurable workspace with folders, annotations, cross-referencing, multi-format import/export, and context-aware capture.

**Why:** Users need more than meeting transcripts. They need a single place for meeting notes, journal entries, bookmarks, images, and the ability to connect ideas across them. Open-source, BYOK (bring your own keys), and local-first gives users ownership. JSON-driven configuration (inspired by VS Code) gives users and contributors a familiar customization model.

**Key numbers:**
- **4 phases** over approximately 12-16 months
- **~20 new Swift files** in Phase 1 (Foundation)
- **~15 new Swift files** in Phase 2 (Intelligence)
- **~10 new Swift files** in Phase 3 (Ecosystem)
- **~8 new Swift files** in Phase 4 (Community)
- **4 new Swift packages**: Yams (Phase 1), Stencil (Phase 2), SwiftSubtitles (Phase 3), iCalendarParser (Phase 3)
- **~12 existing files** modified across all phases

**Current state (pre-transformation):** The app at `wawa-note/` has a working meeting pipeline: record, transcribe (Apple Speech or remote Whisper API), analyze (any OpenAI-compatible provider), export (Markdown/JSON). It uses SwiftData for metadata, FileManager for artifacts, Keychain for secrets. The app builds but has not been validated on a real iPhone 14 Plus.

---

## 2. Target Architecture

### 2.1 Data Model Diagram

```
KnowledgeItem (SwiftData @Model)
  ├── typeRaw: String discriminator → "meeting" | "note" | "journalEntry" | "webBookmark" | "image"
  ├── typeSpecificData: Data? (JSON blob with type-specific fields)
  ├── Top-level columns: title, createdAt, updatedAt, statusRaw, tags, languageCode, durationSeconds
  ├── folderID: UUID? → FK to Folder
  ├── Context columns: contextLatitude, contextLongitude, contextPlaceName,
  │     contextMotionActivity, contextCalendarEventTitle, contextFocusActive,
  │     contextAudioRoute, contextBatteryLevel
  └── (Legacy meeting fields retained: audioFileRelativePath, transcriptionEngineId,
       analysisProviderId, calendarEventIdentifier, isImported, importSourceURL)

Folder (SwiftData @Model)
  ├── parentFolderID: UUID? (self-referencing, root folders have nil)
  ├── name, createdAt, sortOrder
  └── NO @Relationship cascade — manual recursive delete in service layer

Annotation (SwiftData @Model)
  ├── source: String (e.g., "calendar_context", "gps_context", "ai_analysis")
  ├── key: String
  ├── value: String
  ├── itemID: UUID (FK to KnowledgeItem)
  ├── createdAt: Date
  ├── confidence: Double?
  └── Indexes: on itemID, on (key, value), on (itemID, key)

(Transcript, TranscriptSegment, Speaker, MeetingAnalysis, and sub-types
 remain as Codable structs stored as JSON files via FileArtifactStore.)

CrossReferenceResult (ephemeral Codable struct, never persisted)
  ├── answer: String
  ├── connections: [Connection]
  │     └── fromItemId, toItemId, relationship, explanation, strength
  ├── insights: [Insight]
  └── contradictions: [Contradiction]
```

### 2.2 File Layout (target)

```
wawa-note/
  App/
    WawaNoteApp.swift                    ← MODIFY: register Folder, Annotation, KnowledgeItem
  Audio/
    AudioCaptureService.swift
    AudioFileWriter.swift
    AudioPlaybackService.swift
    AudioSessionManager.swift
    NowPlayingController.swift
  Connectivity/
    iOSWatchSessionManager.swift
    RecordingCoordinator.swift           ← MODIFY: capture context sensors
    WatchMessageTypes.swift
  ContextCapture/                        ← NEW directory (Phase 1)
    ContextCaptureService.swift
    ContextSensor.swift                  (protocol)
    CalendarContextSensor.swift          (Tier 1)
    AudioRouteSensor.swift               (Tier 1)
    LocationContextSensor.swift          (Tier 2)
    FocusModeSensor.swift                (Tier 2)
    MotionActivitySensor.swift           (Tier 3)
  Domain/
    Calendar/
      CalendarEvent.swift
      CalendarSyncService.swift
    Models/
      KnowledgeItem.swift                ← NEW: replaces MeetingModel role
      Folder.swift                       ← NEW
      Annotation.swift                   ← NEW
      CrossReferenceModels.swift         ← NEW (Phase 2)
      CoCreationModels.swift             ← NEW (Phase 2)
      LensModels.swift                   ← NEW (Phase 2)
      (Existing: Meeting.swift, TranscriptSegment.swift, MeetingAnalysis.swift,
       AIProviderConfig.swift, ChatModels.swift)
    Services/
      KnowledgeItemService.swift         ← NEW: CRUD for KnowledgeItem + Folder
      AnnotationService.swift            ← NEW: upsert/query annotations
      FolderService.swift                ← NEW: recursive delete, tree queries
      CrossReferenceService.swift        ← NEW (Phase 2)
      LensAnalysisService.swift          ← NEW (Phase 2)
      CoCreationService.swift            ← NEW (Phase 2)
      (Existing: AnalysisService.swift, AudioImportService.swift,
       TranscriptChunker.swift, AudioChunker.swift)
    UseCases/
      (reserved for future use case objects)
  Ecosystem/
    Export/
      ExportService.swift                ← NEW: unified export facade
      TemplateRenderer.swift             ← NEW (Phase 2)
      manifest.json                      ← NEW (Phase 2)
      templates/                         ← NEW (Phase 2)
    Import/
      FormatImporter.swift               ← NEW: protocol
      ImportRouter.swift                 ← NEW: dispatch
      ImportService.swift                ← NEW: orchestration
      Importers/
        JSONImporter.swift               ← NEW (Phase 1)
        MarkdownImporter.swift           ← NEW (Phase 2)
        AudioImportService.swift         ← EXISTING (retrofit to protocol)
    (Existing: MarkdownExporter.swift, JSONExporter.swift)
  LocalIntelligence/
    EmbeddingService.swift               ← NEW (Phase 2)
    SemanticSearchService.swift          ← NEW (Phase 2)
    (reserved: LocalNLPService, CoreMLModelRunner)
  Providers/
    (Existing: AIProvider.swift, OpenAICompatibleProvider.swift,
     ProviderRouter.swift, AIConfigService.swift, ActiveProviderManager.swift)
  Storage/
    FileArtifactStore.swift              ← MODIFY: add media/ configs/ paths
    SecureKeyStore.swift
  Transcription/
    (Existing files)
  UI/
    Knowledge/                           ← NEW directory (Phase 1)
      KnowledgeListView.swift
      KnowledgeDetailView.swift
      KnowledgeQueryView.swift           ← NEW (Phase 2)
      ConnectionsFeedView.swift          ← NEW (Phase 2)
      CoCreationView.swift               ← NEW (Phase 2)
    Meetings/                            ← RETAIN as compatibility layer
      (Existing: MeetingsTabView.swift renamed or adapted)
    Home/                                ← MODIFY: updated for workspace
    Recording/                           ← MODIFY: context capture integration
    Chat/
    Calendar/
    Import/
    Settings/
    Components/
  Resources/
    ai_config.json                       ← MODIFY: add cross_reference, lenses, embeddings
    navigation_config.json               ← NEW (Phase 1)
    workspace_config.json                ← NEW (Phase 1)
    configs/
      export_templates/                  ← NEW (Phase 2)
    Assets.xcassets/
    Info.plist
  Utilities/
    AppDesign.swift
    Logging.swift
```

### 2.3 Navigation Structure

**Tab 1: Home (Workspace)**
- Quick actions: Record, New Note, Import
- Recent items feed
- Smart filter shortcuts (Today, This Week, Flagged)

**Tab 2: Knowledge (replaces Meetings tab)**
- Sidebar/filter: All Items, by Type, by Folder, Smart Filters
- List view with type badges, context tags
- Detail view with sections driven by `navigation_config.json`

**Tab 3: Ask (Phase 2+)**
- Cross-reference query interface
- Multi-perspective lens selector
- Co-creation workspace

**Tab 4: Settings**
- AI Services, Export Templates, Workspace Config, About

### 2.4 JSON-Driven UI (Registry Pattern)

`navigation_config.json` defines:
```json
{
  "sidebar": [
    {"section": "folders", "label": "Folders"},
    {"section": "smart_filters", "label": "Smart Filters"},
    {"section": "by_type", "label": "By Type"}
  ],
  "smartFilters": [
    {"id": "today", "label": "Today", "predicate": "createdAt == today"},
    {"id": "this_week", "label": "This Week", "predicate": "createdAt >= weekStart"},
    {"id": "action_items", "label": "Action Items", "predicate": "hasPendingActions"}
  ],
  "detailSections": {
    "meeting": ["summary", "transcript", "action_items", "context"],
    "note": ["content", "backlinks", "context"],
    "journalEntry": ["content", "mood", "context"],
    "webBookmark": ["url_preview", "notes", "tags"],
    "image": ["image_viewer", "ocr_text", "notes"]
  }
}
```

The registry pattern maps JSON section keys to `DetailSectionBuilder` protocol conformances:
```swift
protocol DetailSectionBuilder {
    static var sectionKey: String { get }
    func build(item: KnowledgeItem, context: ModelContext) -> AnyView
}
```

This follows the pattern already established by `AIConfigService` loading `ai_config.json` at app start.

---

## 3. Phase 1: Foundation (MVP) -- estimated 6-8 weeks

Phase 1 ships the new data model, folder hierarchy, annotation system, inbox migration, enhanced export, format importer protocol, and Tier 1 context sensors -- all while preserving backward compatibility with existing meetings.

### 3.1 KnowledgeItem Model

**File:** `wawa-note/Domain/Models/KnowledgeItem.swift`

```swift
import Foundation
import SwiftData

enum KnowledgeItemType: String, Codable, CaseIterable {
    case meeting
    case note
    case journalEntry
    case webBookmark
    case image
}

@Model
final class KnowledgeItem {
    @Attribute(.unique) var id: UUID
    var typeRaw: String          // KnowledgeItemType rawValue
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var statusRaw: String
    var tags: [String]

    // Cross-type queryable columns
    var durationSeconds: Double?
    var languageCode: String?
    var folderID: UUID?
    var isFlagged: Bool

    // Type-specific data (JSON blob for fields not shared across types)
    var typeSpecificData: Data?

    // Context columns (optional, populated by ContextCaptureService)
    var contextCalendarEventTitle: String?
    var contextAudioRoute: String?
    var contextPlaceName: String?
    var contextLatitude: Double?
    var contextLongitude: Double?
    var contextFocusActive: Bool?
    var contextMotionActivity: String?
    var contextBatteryLevel: Double?

    // Legacy meeting fields (retained for backward compat)
    var audioFileRelativePath: String?
    var transcriptionEngineId: String?
    var analysisProviderId: String?
    var calendarEventIdentifier: String?
    var scheduledDate: Date?
    var isImported: Bool?
    var importSourceURL: String?

    var type: KnowledgeItemType {
        get { KnowledgeItemType(rawValue: typeRaw) ?? .meeting }
        set { typeRaw = newValue.rawValue }
    }

    var status: MeetingStatus {
        get { MeetingStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: KnowledgeItemType = .meeting,
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: MeetingStatus = .draft,
        tags: [String] = [],
        folderID: UUID? = nil,
        isFlagged: Bool = false,
        typeSpecificData: Data? = nil,
        durationSeconds: Double? = nil,
        languageCode: String? = nil
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statusRaw = status.rawValue
        self.tags = tags
        self.folderID = folderID
        self.isFlagged = isFlagged
        self.typeSpecificData = typeSpecificData
        self.durationSeconds = durationSeconds
        self.languageCode = languageCode
    }
}
```

**Important:** Extend `MeetingStatus` with a new `.archived` case (already present) and add `.draftNote` for non-meeting types. Or keep the existing enum and treat `.draft` appropriately for non-meeting types.

### 3.2 Folder Model

**File:** `wawa-note/Domain/Models/Folder.swift`

```swift
import Foundation
import SwiftData

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var parentFolderID: UUID?    // nil = root folder
    var createdAt: Date
    var sortOrder: Int
    var iconName: String?        // SF Symbol name for custom folder icon

    init(
        id: UUID = UUID(),
        name: String = "",
        parentFolderID: UUID? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.iconName = iconName
    }
}
```

**Design decision:** Do NOT use `@Relationship` with cascade delete. Instead, `FolderService.deleteFolder(_:)` manually queries child folders and items, then deletes them bottom-up. This avoids SwiftData cascade bugs and gives explicit control over artifact cleanup.

### 3.3 Annotation Model

**File:** `wawa-note/Domain/Models/Annotation.swift`

```swift
import Foundation
import SwiftData

@Model
final class Annotation {
    var id: UUID
    var source: String       // e.g. "calendar_context", "gps_context", "ai_lens"
    var key: String
    var value: String
    var itemID: UUID
    var createdAt: Date
    var confidence: Double?

    init(
        id: UUID = UUID(),
        source: String,
        key: String,
        value: String,
        itemID: UUID,
        createdAt: Date = Date(),
        confidence: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.key = key
        self.value = value
        self.itemID = itemID
        self.createdAt = createdAt
        self.confidence = confidence
    }
}
```

**Index configuration** is handled in `WawaNoteApp.swift` model container setup using `#Index` macros or manual `ModelConfiguration` with index expressions.

**AnnotationService upsert pattern:**
```swift
func upsert(annotations: [Annotation], itemID: UUID, source: String) throws {
    // 1. Delete existing annotations for (itemID, source)
    let existing = try context.fetch(
        FetchDescriptor<Annotation>(
            predicate: #Predicate { $0.itemID == itemID && $0.source == source }
        )
    )
    for ann in existing { context.delete(ann) }
    // 2. Insert new
    for ann in annotations { context.insert(ann) }
    try context.save()
}
```

**Compound query pattern:**
```swift
func itemsWithKeyValue(key: String, value: String) throws -> [KnowledgeItem] {
    let anns = try context.fetch(
        FetchDescriptor<Annotation>(
            predicate: #Predicate { $0.key == key && $0.value == value }
        )
    )
    let itemIDs = Set(anns.map(\.itemID))
    return try context.fetch(
        FetchDescriptor<KnowledgeItem>(
            predicate: #Predicate { itemIDs.contains($0.id) }
        )
    )
}
```

### 3.4 File Storage Layout

Extend `FileArtifactStore` / Application Support to:

```
Application Support/
  items/
    {uuid}/                          ← replaces Meetings/{uuid}/
      audio.m4a
      transcript.json
      transcript_partial.json
      analysis.json
      provider.response.raw.txt
      exports/                       ← per-item exports
  media/
    {contentHash}_{ext}              ← deduplicated media (images, etc.)
  configs/
    navigation_config.json
    workspace_config.json
    export_templates/                ← Phase 2
      manifest.json
      meeting_minutes.stencil
      executive_summary.stencil
```

`FileArtifactStore` modifications:
- Add `itemDirectoryURL(for:)` method (alias existing `meetingDirectoryURL` for backward compat)
- Add `mediaURL(for contentHash:ext:)` returning `baseURL/../media/{hash}.{ext}`
- Add `configsDirectoryURL()` returning `baseURL/../configs/`
- Keep existing meeting-specific methods as deprecated convenience wrappers

### 3.5 FormatImporter Protocol

**File:** `wawa-note/Ecosystem/Import/FormatImporter.swift`

```swift
import Foundation

struct ImportResult {
    let knowledgeItem: KnowledgeItem
    let artifacts: [String: URL]   // filename -> temp URL for import service to move
    let warnings: [String]
}

protocol FormatImporter {
    /// Unique identifier, e.g. "json", "markdown", "audio_m4a"
    var formatIdentifier: String { get }
    /// Display name shown in UI
    var displayName: String { get }
    /// UTI types this importer handles
    var supportedUTTypes: [UTType] { get }
    /// Check if importer can read this URL (by extension or content sniffing)
    func canRead(url: URL) -> Bool
    /// Can this importer handle raw Data (e.g., from pasteboard)?
    func canRead(data: Data) -> Bool
    /// Import from URL into KnowledgeItem
    func importFromURL(_ url: URL) async throws -> ImportResult
}
```

**File:** `wawa-note/Ecosystem/Import/ImportRouter.swift`

```swift
final class ImportRouter {
    private let importers: [any FormatImporter]

    init(importers: [any FormatImporter]) {
        self.importers = importers
    }

    func importer(for url: URL) -> (any FormatImporter)? {
        importers.first { $0.canRead(url: url) }
    }

    func importer(for data: Data) -> (any FormatImporter)? {
        importers.first { $0.canRead(data: data) }
    }
}
```

**Migration of AudioImportService:** Retrofit `AudioImportService` to conform to `FormatImporter`:
```swift
extension AudioImportService: FormatImporter {
    var formatIdentifier: String { "audio" }
    var displayName: String { "Audio File" }
    var supportedUTTypes: [UTType] {
        [.mpeg4Audio, .mp3, .wav, .aiff]
    }
    // canRead already exists; add canRead(data:) returning false
    // wrap existing import flow into importFromURL
}
```

### 3.6 JSONImporter (Phase 1)

**File:** `wawa-note/Ecosystem/Import/Importers/JSONImporter.swift`

Reads a JSON file conforming to a `KnowledgeItemExport` schema (matching the enhanced JSON export format with `version`, `schema`, `item`, `transcript`, `analysis`). Creates a `KnowledgeItem`, writes transcript/analysis artifacts via `FileArtifactStore`, and returns `ImportResult`.

### 3.7 Enhanced Export

**Modify** `MarkdownExporter.swift` to add YAML frontmatter using the Yams package:
```yaml
---
title: "Q2 Planning Meeting"
date: 2026-05-26T10:00:00Z
duration: 3600
type: meeting
tags: [planning, q2]
status: analyzed
---
```

**Modify** `JSONExporter.swift` to add version and schema fields:
```json
{
  "version": "2.0",
  "schema": "wawa-note/knowledge-item/v1",
  "exportedAt": "2026-05-26T...",
  "item": { ... },
  "transcript": { ... },
  "analysis": { ... }
}
```

**New file:** `wawa-note/Ecosystem/Export/ExportService.swift` -- unified export facade:
```swift
final class ExportService {
    func exportMarkdown(item: KnowledgeItem, transcript: Transcript?, analysis: MeetingAnalysis?) -> String
    func exportJSON(item: KnowledgeItem, transcript: Transcript?, analysis: MeetingAnalysis?) throws -> Data
    func exportSRT(transcript: Transcript) -> String   // ~30 lines, hand-rolled
}
```

### 3.8 SRT Export

**Inside `ExportService.swift` or standalone `SRTExporter.swift`:**
```swift
func exportSRT(transcript: Transcript) -> String {
    var srt = ""
    for (i, seg) in transcript.segments.enumerated() {
        srt += "\(i + 1)\n"
        srt += "\(formatSRTTime(seg.startTime)) --> \(formatSRTTime(seg.endTime ?? seg.startTime + 5))\n"
        srt += "\(seg.text)\n\n"
    }
    return srt
}
// formatSRTTime: "00:02:15,300" (HH:MM:SS,mmm)
```

### 3.9 Context Sensors

**File:** `wawa-note/ContextCapture/ContextSensor.swift`

```swift
protocol ContextSensor {
    var sensorName: String { get }
    func capture() async throws -> [Annotation]
}
```

**File:** `wawa-note/ContextCapture/ContextCaptureService.swift`

```swift
final class ContextCaptureService {
    private let sensors: [any ContextSensor]

    init(sensors: [any ContextSensor] = ContextCaptureService.defaultSensors()) {
        self.sensors = sensors
    }

    static func defaultSensors() -> [any ContextSensor] {
        [CalendarContextSensor(), AudioRouteSensor()]
    }

    func captureAll() async -> [Annotation] {
        await withTaskGroup(of: [Annotation].self) { group in
            for sensor in sensors {
                group.addTask {
                    (try? await sensor.capture()) ?? []
                }
            }
            var all: [Annotation] = []
            for await result in group { all.append(contentsOf: result) }
            return all
        }
    }
}
```

**Tier 1 -- Calendar Context Sensor**
`wawa-note/ContextCapture/CalendarContextSensor.swift`:
- Uses existing `CalendarSyncService` which already wraps `EKEventStore`
- At recording start, queries events overlapping with `Date()`
- Tags: "During Q2 Planning", "5min before Standup"
- Stores as Annotation with `source: "calendar_context"`, `key: "proximity"`, value: event title

**Tier 1 -- Audio Route Sensor**
`wawa-note/ContextCapture/AudioRouteSensor.swift`:
- Uses `AVAudioSession.sharedInstance().currentRoute.outputs`
- Detects: AirPods, speaker, built-in mic, Bluetooth headset
- Stores as Annotation: `source: "audio_route"`, `key: "route_type"`, value: portType

### 3.10 RecordingCoordinator Modifications

In `connectivity/RecordingCoordinator.swift`, modify `startRecording()` to:
1. After inserting the meeting, call `ContextCaptureService.captureAll()`
2. Write captured annotations via `AnnotationService.upsert()`
3. Attach calendar event title to `KnowledgeItem.contextCalendarEventTitle`

### 3.11 Migration: MeetingModel to KnowledgeItem

The `ModelContainer` in `WawaNoteApp.swift` must be updated to include `KnowledgeItem.self`, `Folder.self`, `Annotation.self` alongside existing `MeetingModel.self`.

**Migration strategy (lightweight):**
1. Keep `MeetingModel` as a registered SwiftData model (do not delete it)
2. Add `KnowledgeItem` as a new model
3. On first launch post-upgrade, run a migration pass:
   - Query all `MeetingModel` records
   - For each, create a `KnowledgeItem` with `typeRaw = "meeting"`, copying all shared fields
   - Auto-assign migrated meetings to an "Inbox" folder (create if not exists)
   - Set `folderID` on each migrated item to the Inbox folder ID
   - Copy legacy-specific fields (audioFileRelativePath, transcriptionEngineId, etc.) directly
   - Do NOT delete original `MeetingModel` records on first migration -- keep both for safety
4. Use `UserDefaults` flag `"knowledge_item_migration_completed"` to ensure migration runs only once
5. New code paths use `KnowledgeItem`. UI adapts via `type` discriminator.
6. MeetingModel is retained in the schema for reading legacy data; `MeetingDetailView` continues to work with `MeetingModel` entries while `KnowledgeDetailView` handles new items.

**Migration file:** `wawa-note/Domain/Services/MigrationService.swift`

```swift
final class MigrationService {
    func migrateIfNeeded(context: ModelContext, fileStore: FileArtifactStore) throws {
        guard !UserDefaults.standard.bool(forKey: "knowledge_item_migration_completed") else { return }

        let meetings = try context.fetch(FetchDescriptor<MeetingModel>())
        guard !meetings.isEmpty else {
            UserDefaults.standard.set(true, forKey: "knowledge_item_migration_completed")
            return
        }

        // Create Inbox folder
        let inbox = Folder(name: "Inbox", parentFolderID: nil, sortOrder: 0)
        context.insert(inbox)

        for meeting in meetings {
            let item = KnowledgeItem(
                id: meeting.id,
                type: .meeting,
                title: meeting.title,
                createdAt: meeting.createdAt,
                updatedAt: meeting.updatedAt,
                status: meeting.status,
                tags: meeting.tags,
                folderID: inbox.id,
                durationSeconds: meeting.durationSeconds,
                languageCode: meeting.languageCode
            )
            item.audioFileRelativePath = meeting.audioFileRelativePath
            item.transcriptionEngineId = meeting.transcriptionEngineId
            item.analysisProviderId = meeting.analysisProviderId
            item.calendarEventIdentifier = meeting.calendarEventIdentifier
            item.scheduledDate = meeting.scheduledDate
            item.isImported = meeting.isImported
            item.importSourceURL = meeting.importSourceURL
            context.insert(item)
        }

        try context.save()
        UserDefaults.standard.set(true, forKey: "knowledge_item_migration_completed")
    }
}
```

### 3.12 navigation_config.json

**File:** `wawa-note/Resources/navigation_config.json`

Defines sidebar sections, smart filters, and detail view section ordering for each item type. Loaded by a new `NavigationConfigService` following the `AIConfigService` pattern (load from bundle, parse, expose query methods).

### 3.13 Phase 1 File Inventory

**New files to create:**
1. `wawa-note/Domain/Models/KnowledgeItem.swift`
2. `wawa-note/Domain/Models/Folder.swift`
3. `wawa-note/Domain/Models/Annotation.swift`
4. `wawa-note/Domain/Services/KnowledgeItemService.swift`
5. `wawa-note/Domain/Services/AnnotationService.swift`
6. `wawa-note/Domain/Services/FolderService.swift`
7. `wawa-note/Domain/Services/MigrationService.swift`
8. `wawa-note/Ecosystem/Import/FormatImporter.swift`
9. `wawa-note/Ecosystem/Import/ImportRouter.swift`
10. `wawa-note/Ecosystem/Import/ImportService.swift`
11. `wawa-note/Ecosystem/Import/Importers/JSONImporter.swift`
12. `wawa-note/Ecosystem/Export/ExportService.swift`
13. `wawa-note/Ecosystem/Export/SRTExporter.swift` (or inline in ExportService)
14. `wawa-note/ContextCapture/ContextSensor.swift`
15. `wawa-note/ContextCapture/ContextCaptureService.swift`
16. `wawa-note/ContextCapture/CalendarContextSensor.swift`
17. `wawa-note/ContextCapture/AudioRouteSensor.swift`
18. `wawa-note/UI/Knowledge/KnowledgeListView.swift`
19. `wawa-note/UI/Knowledge/KnowledgeDetailView.swift`
20. `wawa-note/Resources/navigation_config.json`
21. `wawa-note/Resources/workspace_config.json`
22. `wawa-note/Domain/Services/NavigationConfigService.swift`

**Existing files to modify:**
1. `wawa-note/App/WawaNoteApp.swift` -- register new models in ModelContainer, run migration on launch
2. `wawa-note/Domain/Models/SwiftDataModels.swift` -- keep MeetingModel and AIProviderConfigModel (legacy compat), consider deprecation annotation
3. `wawa-note/Storage/FileArtifactStore.swift` -- add `itemDirectoryURL`, `mediaURL`, `configsDirectoryURL` methods
4. `wawa-note/Connectivity/RecordingCoordinator.swift` -- integrate ContextCaptureService in startRecording()
5. `wawa-note/Ecosystem/MarkdownExporter.swift` -- add YAML frontmatter
6. `wawa-note/Ecosystem/JSONExporter.swift` -- add version/schema fields
7. `wawa-note/Ecosystem/AudioImportService.swift` -- retrofit to conform to FormatImporter
8. `wawa-note/UI/Home/HomeView.swift` -- update for workspace concept
9. `wawa-note/UI/Components/ContentView.swift` -- update tabs (add Knowledge tab, rename Meetings)
10. `wawa-note/UI/Meetings/MeetingsTabView.swift` -- adapt to Knowledge model
11. `wawa-note/UI/Meetings/MeetingDetailView.swift` -- bridge to work with KnowledgeItem
12. `project.yml` -- add Yams package dependency

---

## 4. Phase 2: Intelligence -- estimated 8-10 weeks

Phase 2 adds cross-reference queries, multi-perspective lens analysis, co-creation UI, embedding infrastructure, semantic search, Markdown/JSON import, the Stencil template system, GPS context, and Focus context.

### 4.1 CrossReferenceResult Model

**File:** `wawa-note/Domain/Models/CrossReferenceModels.swift`

```swift
struct CrossReferenceResult: Codable {
    let answer: String
    let connections: [Connection]
    let insights: [Insight]
    let contradictions: [Contradiction]
}

struct Connection: Codable, Identifiable {
    var id: UUID = UUID()
    let fromItemId: UUID
    let toItemId: UUID
    let relationship: String
    let explanation: String
    let strength: Double       // 0.0 to 1.0
}

struct Insight: Codable, Identifiable {
    var id: UUID = UUID()
    let text: String
    let sourceItemIds: [UUID]
    let confidence: Double
}

struct Contradiction: Codable, Identifiable {
    var id: UUID = UUID()
    let description: String
    let itemAId: UUID
    let itemBId: UUID
    let resolution: String?
}
```

### 4.2 Embedding Service

**File:** `wawa-note/LocalIntelligence/EmbeddingService.swift`

- Uses the existing `AIProvider` abstraction extended with `supportsEmbeddings: true`
- Sends `/embeddings` requests to the configured provider
- Caches embedding vectors as flat JSON files in `items/{uuid}/embeddings.json`
- Extend `OpenAICompatibleProvider` to handle `/embeddings` endpoint
- Extend `AIProviderCapabilities` to support `supportsEmbeddings: true`

### 4.3 Semantic Search Service

**File:** `wawa-note/LocalIntelligence/SemanticSearchService.swift`

- Generates embedding for the user query
- Brute-force cosine similarity against all cached item embeddings (fine for <10k items)
- Returns ranked list of item IDs with similarity scores
- Tiered context strategy: titles first, then summaries, then entities, then full transcript -- based on token budget

### 4.4 Cross-Reference Service

**File:** `wawa-note/Domain/Services/CrossReferenceService.swift`

Two-pass process:
1. **Semantic search pass:** Use `SemanticSearchService` to find top 5-10 relevant items
2. **AI synthesis pass:** Send the user question + relevant item summaries to the AI provider, receive structured `CrossReferenceResult`

```swift
func query(_ question: String, across itemIDs: [UUID]) async throws -> CrossReferenceResult {
    // 1. Semantic search
    let relevant = try await semanticSearch.findRelevant(query: question, in: itemIDs, limit: 10)

    // 2. Build tiered context based on token budget
    let context = try buildContext(from: relevant, tokenBudget: 4096)

    // 3. AI synthesis
    let prompt = renderCrossReferencePrompt(question: question, context: context)
    let response = try await provider.send(AIRequest(model: model, messages: [
        AIMessage(role: .system, content: [.text(systemPrompt)]),
        AIMessage(role: .user, content: [.text(prompt)])
    ]))

    return parseCrossReferenceResponse(response.content)
}
```

### 4.5 Lens Analysis

**Extend `ai_config.json`** with a `lenses` section:
```json
"lenses": {
  "executive_summary": {
    "name": "Executive Summary",
    "systemPrompt": "You are an executive coach...",
    "userPrompt": "Analyze this content from an executive perspective...",
    "temperature": 0.3,
    "maxTokens": 2000
  },
  "risk_analysis": { ... },
  "design_critique": { ... }
}
```

**File:** `wawa-note/Domain/Services/LensAnalysisService.swift`

- Loads lens configurations from `AIConfigService`
- Runs one or more lenses on selected content (single item or cross-reference context)
- Returns `LensResult` with lens name, output text, and metadata
- Supports side-by-side comparison: run multiple lenses, display results in tabs/cards

### 4.6 Co-Creation UI

**File:** `wawa-note/Domain/Models/CoCreationModels.swift`

```swift
enum CocreationPhase: String, Codable {
    case humanDraft      // User writes initial content
    case aiSuggesting    // AI proposes refinements
    case humanReviewing  // User reviews AI suggestions
    case aiPolishing     // AI applies approved changes
    case complete
}
```

**File:** `wawa-note/UI/Knowledge/CoCreationView.swift`

- State machine: human draft -> AI suggest -> human review -> AI polish -> complete
- AI-generated text shown with tinted background (Color.blue.opacity(0.1)) + sparkle icon
- Suggested connections (between items) shown as cards with accept/dismiss buttons
- Edit tracking: leverages existing `TranscriptSegment.originalText` pattern -- original text preserved alongside edited version

### 4.7 Connections Feed View

**File:** `wawa-note/UI/Knowledge/ConnectionsFeedView.swift`

- MVP: Scrollable card list, NOT a visual graph
- Each card: "Meeting A -> [relationship] -> Note B" with explanation
- v2 (Phase 3): SwiftUI Canvas with simple force-directed layout
- v3 (Phase 4): SpriteKit for interactive graph

### 4.8 MarkdownImporter (Phase 2)

**File:** `wawa-note/Ecosystem/Import/Importers/MarkdownImporter.swift`

- Parses YAML frontmatter (using Yams) for metadata
- Parses markdown body into structured content
- Creates `KnowledgeItem` with `typeRaw: "note"`
- Respects `title`, `date`, `tags`, `type` from frontmatter

### 4.9 Template System with Stencil

**File:** `wawa-note/Ecosystem/Export/TemplateRenderer.swift`

```swift
import Stencil

final class TemplateRenderer {
    private let environment: Environment

    init(templateDirectory: URL) {
        let loader = FileSystemLoader(paths: [templateDirectory.path])
        self.environment = Environment(loader: loader)
    }

    func render(template: String, context: [String: Any]) throws -> String {
        try environment.renderTemplate(name: template, context: context)
    }
}
```

**File:** `wawa-note/Resources/configs/export_templates/manifest.json`
```json
{
  "templates": [
    {"id": "meeting_minutes", "name": "Meeting Minutes (HTML)", "file": "meeting_minutes.stencil", "format": "html"},
    {"id": "executive_summary", "name": "Executive Summary (MD)", "file": "executive_summary.stencil", "format": "md"}
  ]
}
```

### 4.10 HTML Export

`meeting_minutes.stencil` template generating a clean HTML meeting minutes document from KnowledgeItem + transcript + analysis context.

### 4.11 Tier 2 Context Sensors

**Location Context Sensor:**
`wawa-note/ContextCapture/LocationContextSensor.swift`
- `CLLocationManager.requestLocation()` once at recording start
- `CLGeocoder.reverseGeocodeLocation()` for place name
- Requires `NSLocationWhenInUseUsageDescription` in Info.plist
- One-shot location request, not continuous tracking
- Stores as Annotation: `source: "location"`, key: "place_name"/"latitude"/"longitude"

**Focus Mode Sensor:**
`wawa-note/ContextCapture/FocusModeSensor.swift`
- `INFocusStatusCenter.default.focusStatus.isFocused`
- Zero permissions required
- Stores as Annotation: `source: "focus_mode"`, key: "is_focused", value: "true"/"false"

### 4.12 Knowledge Query View

**File:** `wawa-note/UI/Knowledge/KnowledgeQueryView.swift`

A search-like interface where users type a natural language question about their knowledge items, and the app runs cross-reference queries. Results displayed as structured cards (answer, connections, insights, contradictions).

### 4.13 Phase 2 File Inventory

**New files to create:**
1. `wawa-note/Domain/Models/CrossReferenceModels.swift`
2. `wawa-note/Domain/Models/CoCreationModels.swift`
3. `wawa-note/Domain/Models/LensModels.swift`
4. `wawa-note/Domain/Services/CrossReferenceService.swift`
5. `wawa-note/Domain/Services/LensAnalysisService.swift`
6. `wawa-note/Domain/Services/CoCreationService.swift`
7. `wawa-note/LocalIntelligence/EmbeddingService.swift`
8. `wawa-note/LocalIntelligence/SemanticSearchService.swift`
9. `wawa-note/Ecosystem/Export/TemplateRenderer.swift`
10. `wawa-note/Ecosystem/Import/Importers/MarkdownImporter.swift`
11. `wawa-note/ContextCapture/LocationContextSensor.swift`
12. `wawa-note/ContextCapture/FocusModeSensor.swift`
13. `wawa-note/UI/Knowledge/KnowledgeQueryView.swift`
14. `wawa-note/UI/Knowledge/ConnectionsFeedView.swift`
15. `wawa-note/UI/Knowledge/CoCreationView.swift`
16. `wawa-note/Resources/configs/export_templates/manifest.json`
17. `wawa-note/Resources/configs/export_templates/meeting_minutes.stencil`
18. `wawa-note/Resources/configs/export_templates/executive_summary.stencil`

**Existing files to modify:**
1. `wawa-note/Providers/AIProvider.swift` -- add embedding support to capabilities, extend request/response types
2. `wawa-note/Providers/OpenAICompatibleProvider.swift` -- add `/embeddings` endpoint support
3. `wawa-note/Providers/ProviderRouter.swift` -- add embedding capability to constructed providers
4. `wawa-note/Resources/ai_config.json` -- add `cross_reference` feature, `lenses` section
5. `wawa-note/App/WawaNoteApp.swift` -- register new ModelContainer schemas if needed
6. `project.yml` -- add Stencil package dependency

---

## 5. Phase 3: Ecosystem -- estimated 8-10 weeks

Phase 3 adds OPML, ICS, VTT format support, motion context, user custom templates, and graph visualization.

### 5.1 Additional Format Importers

**OPMLImporter** (`wawa-note/Ecosystem/Import/Importers/OPMLImporter.swift`):
- Parse OPML XML (outline hierarchy) using Foundation's `XMLParser`
- Create Folder hierarchy + KnowledgeItem entries for each outline node

**ICSImporter** (`wawa-note/Ecosystem/Import/Importers/ICSImporter.swift`):
- Parse iCalendar files using `iCalendarParser` Swift package
- Create KnowledgeItem entries with `scheduledDate` set, type `meeting` or `journalEntry`

**VTTImporter and SRTImporter**:
- Use `SwiftSubtitles` package for VTT parsing
- SRT parsing: hand-rolled (~30 lines)
- Creates KnowledgeItem entries with transcript segments

### 5.2 Additional Format Exporters

**ICSExport:** Generate iCalendar file from KnowledgeItem for calendar import
**VTTExport:** Generate WebVTT captions from transcript (via SwiftSubtitles)
**OPMLExport:** Generate OPML from folder hierarchy for outline tool import

### 5.3 User Custom Templates

- Templates stored in `configs/export_templates/` directory
- Each template directory contains `.stencil` file + `manifest.json` entry
- User can add templates via Files app (open directory in Files), import from URL, or create in-app
- Template editor: simple text editor in Settings for editing .stencil files

### 5.4 Graph Visualization

**v2 implementation** (Phase 3):
`wawa-note/UI/Knowledge/KnowledgeGraphView.swift`
- Uses SwiftUI `Canvas` with force-directed layout algorithm
- Nodes = KnowledgeItems (color-coded by type)
- Edges = connections from CrossReferenceResult
- Tap node to navigate to item detail

**v3 implementation** (Phase 4):
- SpriteKit-based interactive graph with physics
- Pinch-to-zoom, drag nodes, spring-loaded connections

### 5.5 Tier 3 Context Sensor

**Motion Activity Sensor:**
`wawa-note/ContextCapture/MotionActivitySensor.swift`
- `CMMotionActivityManager` for motion detection
- Requires `NSMotionUsageDescription` in Info.plist
- Captures: stationary, walking, running, automotive, cycling
- Many users deny this permission -- clearly opt-in with explanation
- Stores as Annotation: `source: "motion"`, key: "activity_type"

**Battery State Sensor:**
`wawa-note/ContextCapture/BatterySensor.swift`
- `UIDevice.current.batteryState` / `batteryLevel`
- UIDevice must have `isBatteryMonitoringEnabled = true` first
- Low user value, mainly for diagnostics
- Stores as Annotation: `source: "battery"`, key: "state"/"level"

### 5.6 Phase 3 File Inventory

**New files to create:**
1. `wawa-note/Ecosystem/Import/Importers/OPMLImporter.swift`
2. `wawa-note/Ecosystem/Import/Importers/ICSImporter.swift`
3. `wawa-note/Ecosystem/Import/Importers/VTTImporter.swift`
4. `wawa-note/Ecosystem/Import/Importers/SRTImporter.swift`
5. `wawa-note/Ecosystem/Export/ICSExporter.swift`
6. `wawa-note/Ecosystem/Export/VTTExporter.swift`
7. `wawa-note/Ecosystem/Export/OPMLExporter.swift`
8. `wawa-note/ContextCapture/MotionActivitySensor.swift`
9. `wawa-note/ContextCapture/BatterySensor.swift`
10. `wawa-note/UI/Knowledge/KnowledgeGraphView.swift`

**Existing files to modify:**
1. `wawa-note/Ecosystem/Import/ImportRouter.swift` -- register new importers
2. `wawa-note/Ecosystem/Export/ExportService.swift` -- add new export methods
3. `project.yml` -- add SwiftSubtitles, iCalendarParser packages

---

## 6. Phase 4: Community -- estimated 6-8 weeks

Phase 4 adds a plugin/extension system, template marketplace (community sharing), and external service integrations.

### 6.1 Plugin/Extension System

A lightweight plugin system allowing developers to contribute format importers, exporters, context sensors, and AI lenses without modifying core app code.

**Mechanism:** Plugins are Swift packages that conform to a plugin protocol. The core app discovers plugins at build time via a plugin registry (JSON manifest). Dynamic plugin loading is not supported on iOS (no dlopen for third-party code), so plugins are compiled into the app.

```swift
protocol WawaPlugin {
    var identifier: String { get }
    var displayName: String { get }
    var version: String { get }
    var author: String { get }
    var formatImporters: [any FormatImporter] { get }
    var formatExporters: [any FormatExporter] { get }
    var contextSensors: [any ContextSensor] { get }
    var lenses: [LensConfig] { get }
}
```

### 6.2 Template Marketplace

- Templates stored in a public GitHub repository
- App can browse, preview, and install templates from the repo
- Template validation: ensure .stencil files compile, test with sample data
- Version tracking: templates have semantic versions, app checks for updates

### 6.3 External Service Integrations (Optional/Free)

- **GitHub Gist:** Export/import KnowledgeItems as gists
- **Cloudflare R2:** Optional cloud backup for items (encrypted client-side)
- **iCloud:** Sync metadata via CloudKit (encrypted, opt-in)
- **WebDAV:** Export to WebDAV servers (NextCloud, ownCloud)

### 6.4 Phase 4 File Inventory

**New files to create:**
1. `wawa-note/Domain/Plugins/WawaPlugin.swift` (protocol)
2. `wawa-note/Domain/Plugins/PluginRegistry.swift`
3. `wawa-note/Domain/Services/TemplateMarketplaceService.swift`
4. `wawa-note/Ecosystem/Integrations/GistIntegrationService.swift`
5. `wawa-note/Ecosystem/Integrations/CloudflareR2Service.swift`
6. `wawa-note/Ecosystem/Integrations/WebDAVService.swift`
7. `wawa-note/UI/Settings/TemplateMarketplaceView.swift`
8. `wawa-note/UI/Settings/PluginSettingsView.swift`

**Existing files to modify:**
1. `project.yml` -- add optional integration dependencies
2. `wawa-note/App/WawaNoteApp.swift` -- plugin discovery and registration

---

## 7. Migration Strategy

### 7.1 Phase 0: Pre-Migration (Before Phase 1)

1. **Tag current state:** `git tag pre-transformation-v1.0`
2. **Ensure all existing tests pass** (or document current failures)
3. **Back up any real meeting data** from test devices
4. **Document known issues** in `PROJECT_STATUS.md`

### 7.2 Phase 1 Migration Tasks

1. Add `KnowledgeItem`, `Folder`, `Annotation` as SwiftData models alongside existing `MeetingModel`
2. Implement `MigrationService.migrateIfNeeded()` with the following logic:
   - Check `UserDefaults` flag; skip if already migrated
   - Fetch all `MeetingModel` records
   - Create "Inbox" Folder
   - For each MeetingModel, create corresponding KnowledgeItem with `typeRaw: "meeting"` and `folderID: inbox.id`
   - Copy all shared fields
   - Preserve original MeetingModel records (do not delete)
   - Set migration flag
3. **Data preservation:** Audio files, transcripts, and analyses remain in their existing `Meetings/{uuid}/` directories. `FileArtifactStore` adds new paths alongside, keeping backward compatibility with a `meetingDirectoryURL` compatibility method that delegates to `itemDirectoryURL`.

### 7.3 Phase 2+ Migration Considerations

- `MeetingModel` is eventually soft-deprecated (marked with comments, not removed)
- New UI code paths use `KnowledgeItem` exclusively
- `MeetingDetailView` continues working via a compatibility bridge that wraps `MeetingModel` into a `KnowledgeItem`-compatible view
- After Phase 3, `MeetingModel` can be removed from the schema entirely (requires another migration pass to ensure zero MeetingModel records remain)

---

## 8. File Inventory (Complete)

### 8.1 New Files by Phase

**Phase 1 (22 files):**
1. `wawa-note/Domain/Models/KnowledgeItem.swift`
2. `wawa-note/Domain/Models/Folder.swift`
3. `wawa-note/Domain/Models/Annotation.swift`
4. `wawa-note/Domain/Services/KnowledgeItemService.swift`
5. `wawa-note/Domain/Services/AnnotationService.swift`
6. `wawa-note/Domain/Services/FolderService.swift`
7. `wawa-note/Domain/Services/MigrationService.swift`
8. `wawa-note/Domain/Services/NavigationConfigService.swift`
9. `wawa-note/Ecosystem/Import/FormatImporter.swift`
10. `wawa-note/Ecosystem/Import/ImportRouter.swift`
11. `wawa-note/Ecosystem/Import/ImportService.swift`
12. `wawa-note/Ecosystem/Import/Importers/JSONImporter.swift`
13. `wawa-note/Ecosystem/Export/ExportService.swift`
14. `wawa-note/ContextCapture/ContextSensor.swift`
15. `wawa-note/ContextCapture/ContextCaptureService.swift`
16. `wawa-note/ContextCapture/CalendarContextSensor.swift`
17. `wawa-note/ContextCapture/AudioRouteSensor.swift`
18. `wawa-note/UI/Knowledge/KnowledgeListView.swift`
19. `wawa-note/UI/Knowledge/KnowledgeDetailView.swift`
20. `wawa-note/Resources/navigation_config.json`
21. `wawa-note/Resources/workspace_config.json`
22. (Optional) `wawa-note/Ecosystem/Export/SRTExporter.swift`

**Phase 2 (18 files):**
1. `wawa-note/Domain/Models/CrossReferenceModels.swift`
2. `wawa-note/Domain/Models/CoCreationModels.swift`
3. `wawa-note/Domain/Models/LensModels.swift`
4. `wawa-note/Domain/Services/CrossReferenceService.swift`
5. `wawa-note/Domain/Services/LensAnalysisService.swift`
6. `wawa-note/Domain/Services/CoCreationService.swift`
7. `wawa-note/LocalIntelligence/EmbeddingService.swift`
8. `wawa-note/LocalIntelligence/SemanticSearchService.swift`
9. `wawa-note/Ecosystem/Export/TemplateRenderer.swift`
10. `wawa-note/Ecosystem/Import/Importers/MarkdownImporter.swift`
11. `wawa-note/ContextCapture/LocationContextSensor.swift`
12. `wawa-note/ContextCapture/FocusModeSensor.swift`
13. `wawa-note/UI/Knowledge/KnowledgeQueryView.swift`
14. `wawa-note/UI/Knowledge/ConnectionsFeedView.swift`
15. `wawa-note/UI/Knowledge/CoCreationView.swift`
16. `wawa-note/Resources/configs/export_templates/manifest.json`
17. `wawa-note/Resources/configs/export_templates/meeting_minutes.stencil`
18. `wawa-note/Resources/configs/export_templates/executive_summary.stencil`

**Phase 3 (10 files):**
1. `wawa-note/Ecosystem/Import/Importers/OPMLImporter.swift`
2. `wawa-note/Ecosystem/Import/Importers/ICSImporter.swift`
3. `wawa-note/Ecosystem/Import/Importers/VTTImporter.swift`
4. `wawa-note/Ecosystem/Import/Importers/SRTImporter.swift`
5. `wawa-note/Ecosystem/Export/ICSExporter.swift`
6. `wawa-note/Ecosystem/Export/VTTExporter.swift`
7. `wawa-note/Ecosystem/Export/OPMLExporter.swift`
8. `wawa-note/ContextCapture/MotionActivitySensor.swift`
9. `wawa-note/ContextCapture/BatterySensor.swift`
10. `wawa-note/UI/Knowledge/KnowledgeGraphView.swift`

**Phase 4 (8 files):**
1. `wawa-note/Domain/Plugins/WawaPlugin.swift`
2. `wawa-note/Domain/Plugins/PluginRegistry.swift`
3. `wawa-note/Domain/Services/TemplateMarketplaceService.swift`
4. `wawa-note/Ecosystem/Integrations/GistIntegrationService.swift`
5. `wawa-note/Ecosystem/Integrations/CloudflareR2Service.swift`
6. `wawa-note/Ecosystem/Integrations/WebDAVService.swift`
7. `wawa-note/UI/Settings/TemplateMarketplaceView.swift`
8. `wawa-note/UI/Settings/PluginSettingsView.swift`

### 8.2 Existing Files Modified by Phase

**Phase 1 (12 files):**
1. `wawa-note/App/WawaNoteApp.swift`
2. `wawa-note/Storage/FileArtifactStore.swift`
3. `wawa-note/Connectivity/RecordingCoordinator.swift`
4. `wawa-note/Ecosystem/MarkdownExporter.swift`
5. `wawa-note/Ecosystem/JSONExporter.swift`
6. `wawa-note/Domain/Services/AudioImportService.swift`
7. `wawa-note/UI/Home/HomeView.swift`
8. `wawa-note/UI/Components/ContentView.swift`
9. `wawa-note/UI/Meetings/MeetingsTabView.swift`
10. `wawa-note/UI/Meetings/MeetingDetailView.swift`
11. `wawa-note/UI/Meetings/MeetingsListView.swift`
12. `project.yml`

**Phase 2 (7 files):**
1. `wawa-note/Providers/AIProvider.swift`
2. `wawa-note/Providers/OpenAICompatibleProvider.swift`
3. `wawa-note/Providers/ProviderRouter.swift`
4. `wawa-note/Resources/ai_config.json`
5. `wawa-note/App/WawaNoteApp.swift`
6. `wawa-note/UI/Components/ContentView.swift`
7. `project.yml`

**Phase 3 (3 files):**
1. `wawa-note/Ecosystem/Import/ImportRouter.swift`
2. `wawa-note/Ecosystem/Export/ExportService.swift`
3. `project.yml`

---

## 9. Swift Package Dependencies

| Package | Phase | Purpose | URL |
|---|---|---|---|
| Yams | 1 | YAML frontmatter in Markdown export/import | `https://github.com/jpsim/Yams` |
| Stencil | 2 | Template engine for export templates | `https://github.com/stencilproject/Stencil` |
| SwiftSubtitles | 3 | SRT/VTT subtitle parsing and generation | Community package, needs evaluation |
| iCalendarParser | 3 | ICS file parsing | Community package, needs evaluation |

All packages are added via Swift Package Manager in `project.yml`.

**Additions to project.yml for Phase 1:**
```yaml
packages:
  Yams:
    url: https://github.com/jpsim/Yams
    from: "5.0.0"
```

Then add `Yams` as a dependency of the `wawa-note` target.

---

## 10. Verification

### 10.1 Phase 1 Verification

| Test | Method | Success Criteria |
|---|---|---|
| Build | Xcode build | Zero errors, zero warnings |
| Migration | Launch on simulator with existing MeetingModel data | All meetings appear as KnowledgeItems in Inbox folder |
| Folder CRUD | Manual UI test | Create, rename, nest, delete folders |
| Annotation CRUD | Unit test | Upsert idempotent, compound query returns correct items |
| JSON import | Import test fixture | KnowledgeItem created with correct type and fields |
| Markdown export | Export meeting, inspect output | YAML frontmatter present and valid |
| JSON export | Export meeting, inspect output | `version` and `schema` fields present |
| SRT export | Export transcript, inspect output | Valid SRT format, correct timestamps |
| Calendar context | Record meeting during calendar event | Annotation stored with event proximity |
| Audio route context | Record with AirPods vs speaker | Annotation stores correct route type |
| Backward compat | Open existing meeting from pre-transformation | MeetingDetailView still works |
| File system | Check Application Support | Items stored under `items/{uuid}/`, old `Meetings/{uuid}/` still accessible |

### 10.2 Phase 2 Verification

| Test | Method | Success Criteria |
|---|---|---|
| Cross-reference query | Ask question spanning 3+ meetings | Structured CrossReferenceResult returned |
| Embedding generation | Generate embeddings for 10 items | Embeddings cached as JSON, retrieval works |
| Semantic search | Search with natural language query | Top results are semantically relevant |
| Lens analysis | Run executive_summary lens on meeting | Different output than default analysis |
| Side-by-side lenses | Run risk_analysis and design_critique on same content | Both results displayed, comparable |
| Co-creation flow | Start note, accept AI suggestion | Human->AI->human->AI cycle completes |
| Markdown import | Import .md file with frontmatter | KnowledgeItem + content correctly parsed |
| HTML export | Export meeting with template | Valid HTML document |
| Template rendering | Render with custom .stencil | Correct output with context variables |
| GPS context | Record with location permission | Place name stored as annotation |
| Focus context | Record with Focus mode on | Focus status stored as annotation |

### 10.3 Phase 3 Verification

| Test | Method | Success Criteria |
|---|---|---|
| OPML import | Import OPML from outliner | Folder hierarchy + items created |
| ICS export | Export meeting as .ics | Valid iCalendar file, imports into Apple Calendar |
| VTT export | Export transcript as .vtt | Valid WebVTT, plays in video players |
| ICS import | Import .ics file | KnowledgeItem with scheduledDate |
| SRT import | Import .srt file | KnowledgeItem with transcript |
| Motion context | Record while walking | Motion activity annotation (if permission) |
| Graph visualization | View connected items graph | Nodes + edges displayed, tap navigates |
| User templates | Add custom .stencil template | Appears in export options, renders correctly |

### 10.4 Phase 4 Verification

| Test | Method | Success Criteria |
|---|---|---|
| Plugin registration | Add test plugin package | Importers/sensors registered and functional |
| Gist export | Export item to GitHub Gist | Gist created with correct content |
| WebDAV export | Export to WebDAV server | File appears on server |
| Template marketplace | Browse available templates | List loads, preview works, install works |

---

## 11. Key Design Decisions and Rationale

1. **Single KnowledgeItem model with typeRaw discriminator over class hierarchy.** Rationale: SwiftData does not support inheritance well. A discriminated model with an optional `typeSpecificData` JSON blob gives us polymorphism without subclassing headaches. Shared columns remain queryable.

2. **Annotation as separate @Model, not embedded JSON.** Rationale: Annotations need compound indexes for efficient queries (find all items with `key="calendar_proximity" AND value="During Standup"`). Embedded JSON blobs in SwiftData cannot be indexed. The upsert pattern (delete by itemID+source, re-insert) keeps writes simple and idempotent.

3. **Manual recursive delete over @Relationship cascade.** Rationale: SwiftData's cascade delete behavior has been unreliable in practice. Manual recursive delete in `FolderService` gives explicit control and avoids orphan artifacts.

4. **Flat UUID-based file layout over hierarchical.** Rationale: Items may move between folders. A flat `items/{uuid}/` layout means moves do not require file system changes. The folder hierarchy is purely in the database.

5. **Context stored as Annotations, not hardcoded columns.** Rationale: Allows new context sensors to be added without schema migrations. The columns on KnowledgeItem (contextPlaceName, etc.) are convenience denormalizations for the most commonly queried context values.

6. **CrossReferenceResult is ephemeral, never persisted.** Rationale: Cross-references are generated on-demand and depend on the current state of the knowledge graph. Persisting them would create staleness problems. They are cached in-memory only during the session.

7. **Brute-force cosine similarity over vector database.** Rationale: For <10,000 items, brute-force with Accelerate is simple, has zero dependencies, and performs adequately. A vector database adds complexity that is not justified at this scale.

8. **Stencil over custom template language.** Rationale: Stencil is a mature, well-tested Swift template engine with familiar Mustache-like syntax. It avoids NIH syndrome and gives users a documented template language.

9. **Open-source, no business model.** Rationale: This is a deliberate choice. The app is a knowledge workspace tool, not a SaaS product. Everything is local. BYOK for remote APIs. Free optional services (GitHub Gist, Cloudflare R2 free tier, iCloud, WebDAV).

---

### Critical Files for Implementation

- `/Users/wagnermontes/Documents/GitHub/wawa-note-ios/wawa-note/App/WawaNoteApp.swift`
- `/Users/wagnermontes/Documents/GitHub/wawa-note-ios/wawa-note/Domain/Models/SwiftDataModels.swift`
- `/Users/wagnermontes/Documents/GitHub/wawa-note-ios/wawa-note/Storage/FileArtifactStore.swift`
- `/Users/wagnermontes/Documents/GitHub/wawa-note-ios/wawa-note/Connectivity/RecordingCoordinator.swift`
- `/Users/wagnermontes/Documents/GitHub/wawa-note-ios/wawa-note/Providers/AIProvider.swift`