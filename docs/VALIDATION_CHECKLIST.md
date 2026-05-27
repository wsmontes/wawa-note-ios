# iPhone 14 Plus Validation Checklist

**Date:** 2026-05-27
**Build status:** BUILD SUCCEEDED (iPhone 14 Plus Simulator, Debug, Swift 6.0)

## Simulator Validation

### Navigation
- [x] Home tab renders (header, quick actions, record button, recent items)
- [x] Knowledge tab renders (items list, search, filters, folders)
- [x] Knowledge → Connections (graph icon in toolbar) → EvidenceInspector
- [x] Projects tab renders (project list, empty state)
- [x] Projects → ProjectDetailView → Tasks/Items/Graph/Timeline tabs
- [x] Ask tab renders (query input, template selector)
- [x] Settings tab renders (AI Services, stats, privacy)
- [x] Calendar accessible from Home quick actions

### Recording pipeline (simulator limited — mic not available)
- [x] Record button opens RecordView
- [x] UI renders: status badge, timer, buttons
- [ ] Audio capture (requires physical device microphone)
- [ ] Transcription (requires audio file + Apple Speech authorization)
- [ ] Analysis (requires AI provider configuration)

### Import/Export
- [x] Import file picker opens
- [x] Export menu renders in KnowledgeDetailView toolbar
- [x] Project export menu renders (Markdown, Send to Reminders)
- [x] Promote to Project sheet renders

### Data model
- [x] ModelContainer registers 9 models successfully
- [x] 0 compilation errors with Swift 6 strict concurrency
- [x] KnowledgeItem with polymorphic types (meeting, note, journal, bookmark, image)
- [x] Project, TaskItem, Person, GraphEdge, Entity all compile

### Edge cases
- [x] Empty states render for all tabs
- [ ] Screen lock behavior (simulator limited)
- [ ] Audio interruption (simulator limited)
- [ ] No-network behavior (requires physical device + network control)
- [ ] Provider failure (requires AI provider)

## Physical Device Tests (pending)

These require an iPhone 14 Plus with iOS 18+:

- [ ] Install app via Xcode
- [ ] Grant microphone, speech recognition, calendar permissions
- [ ] Record 5-minute meeting → transcribe → analyze
- [ ] Record 15-minute meeting → transcribe → analyze
- [ ] Record 60-minute meeting → transcribe → analyze
- [ ] Screen lock during recording (verify recording continues)
- [ ] Incoming call during recording (verify graceful handling)
- [ ] Airplane mode (verify local transcription works)
- [ ] Provider misconfiguration (verify error messages)
- [ ] Export Markdown → open in Files.app
- [ ] Promote meeting to project → verify tasks/edges created
- [ ] Ask across multiple meetings → verify cross-reference results
- [ ] Battery drain during 60-min recording
- [ ] Thermal throttling during long transcription

## Test Results

### Unit Tests (compiled, pending xcodebuild test action fix)
17 tests in `CoreServicesTests.swift`:
- `SemanticSearchServiceTests` (5) — cosine similarity: identical, orthogonal, opposite, empty, different lengths
- `CrossReferenceResultTests` (2) — valid JSON parse, minimal JSON parse
- `ProjectExportServiceTests` (2) — empty CSV, CSV with tasks
- `GraphEdgeServiceTests` (1) — all 10 edge types
- `EntityExtractionTests` (1) — EntityType → EntityKind mapping
- `MeetingAnalysisTests` (2) — entity type roundtrip, EntityMention creation

### Build Matrix
| Target | Status |
|---|---|
| iPhone 17 Simulator (Debug) | BUILD SUCCEEDED |
| iPhone 14 Plus Simulator (Debug) | BUILD SUCCEEDED |
| **iPhone 14 Plus Device (arm64)** | **BUILD SUCCEEDED + INSTALLED + LAUNCHED** |
| Tests (compile) | TEST BUILD SUCCEEDED |

### Device Installation (2026-05-27)
- [x] Build for arm64 device: BUILD SUCCEEDED
- [x] Install via devicectl: App installed (bundleID: com.wawa-note)
- [x] Launch on device: Application launched successfully
- [x] No crash on launch
