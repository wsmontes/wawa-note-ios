# Task 3: Unified analysis schema — remove framework templates (KAN-521)

**Goal:** Simplify item analysis to use a SINGLE schema (MeetingAnalysis) for all item types. Remove framework template system.

## Requirements

1. In `ContentPipelineService.swift` PipelineTemplate enum — remove all framework-specific cases (research, brainstorm, journal, coaching, legal, product). Keep only `.standard` and `.extractAndAnalyze`.
2. Delete the `forFramework()` static method on PipelineTemplate.
3. In `AnalysisService.swift` — remove framework resolution. Any place that calls `resolvedFramework.map { PipelineTemplate.forFramework($0) } ?? .standard` should just use `.standard` directly.
4. Build must succeed.

## Files
- `wawa-note/Domain/Services/ContentPipelineService.swift`
- `wawa-note/Domain/Services/AnalysisService.swift`

## Verification

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus,OS=latest' build 2>&1 | \
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3
```

Expected: `** BUILD SUCCEEDED **`

## Commit message

```
KAN-521: unified analysis schema — single MeetingAnalysis for all items, remove framework templates
Co-Authored-By: Claude <noreply@anthropic.com>
```

## Report

Write to `.superpowers/sdd/task-3-report.md`
