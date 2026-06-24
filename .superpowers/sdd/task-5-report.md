# Task 5 Report: Remove project processing (KAN-523)

## Summary

Removed `ProjectAgent`, `ProjectIngestionPipeline`, and Synthesis views. The `feat/mvp-v1` branch already had the synthesis model deprecations, synthesis view deletions, and pbxproj cleanups committed. This task completed the remaining reference cleanup in dependent files.

## Changes Made

### Files deleted (untracked in this branch, removed from filesystem)
- `wawa-note/Domain/Agent/ProjectAgent.swift`
- `wawa-note/Domain/Services/ProjectIngestionPipeline.swift`

### `wawa-note/App/WawaNoteApp.swift`
- Removed `private let ingestionPipeline: ProjectIngestionPipeline` property
- Removed `ingestionPipeline = ProjectIngestionPipeline(ingestionState: ingestionState)` initialization
- Updated `ContentPipelineService(...)` call to remove `ingestionPipeline:` parameter
- Removed `.environmentObject(ingestionPipeline)` injection

### `wawa-note/Domain/Services/ContentPipelineService.swift`
- Removed `private let ingestionPipeline: ProjectIngestionPipeline` property
- Updated `init(...)` to remove `ingestionPipeline:` parameter
- Removed ingestion calls in the skip-if-already-analyzed guard block (lines 176-181)
- Removed the `ingestOnly()` method (was 25 lines) — it only called `ingestionPipeline.ingest()`

### `wawa-note/Domain/Services/BackgroundWorker.swift`
- Moved `IngestionResponse`, `IngestionConnection`, `IngestionTaskUpdate`, `IngestionNewTask`, `IngestionReinforcement`, `IngestionInsight`, `IngestionSignal` Codable types into this file (previously in `ProjectIngestionPipeline.swift`)

### `wawa-note/Domain/Services/PostRecordingAutomationService.swift`
- Updated comment: removed "ProjectIngestionPipeline and" reference

### Pre-existing (already committed on this branch)
- Synthesis models (SynthesisBody, SynthesisSection, SynthesisMetric) already had `@available(*, deprecated)` attributes
- Synthesis views (ProjectSynthesisView, SynthesisContentView, MetricsStripView, SectionCardView, EmptySynthesisView, MetricPill) already deleted from ProjectDetailView.swift
- pbxproj already had no references to ProjectAgent.swift or ProjectIngestionPipeline.swift

## Verification

- **Build result:** `BUILD SUCCEEDED` — `make quick` passed (xcodebuild build + test)
- **Tests:** All 131 tests passed with 0 failures
