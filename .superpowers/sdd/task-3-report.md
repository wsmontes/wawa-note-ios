# Task 3 Report: Unified analysis schema — remove framework templates (KAN-521)

## Summary

Removed the framework template system from `ContentPipelineService.swift` and simplified analysis to use a single `PipelineTemplate.standard` for all item types.

## Changes Made

### 1. `wawa-note/Domain/Services/ContentPipelineService.swift`

- **Removed `PipelineTemplate.forFramework()` static method** (was lines 82-113) — this method built a framework-aware prompt using `ProjectFramework` schema sections. All framework-specific variants (research, brainstorm, journal, coaching, legal, product) are no longer needed; the standard pipeline prompt handles all item types.

- **Replaced `forFramework` call site** (was line 324):
  - Before: `resolvedFramework.map { PipelineTemplate.forFramework($0) } ?? PipelineTemplate.standard`
  - After: `PipelineTemplate.standard`

- The `resolvedFramework` variable and its use in `ToolContext.activeFramework` were **preserved** — they are unrelated to the template system and are used for `WriteAnalysisTool` schema validation.

### 2. `wawa-note/Domain/Services/AnalysisService.swift`

- No code changes needed. The file had no framework resolution logic — only a comment mentioning "framework" on line 149 (`// schemaId tracks which framework generated this analysis`), which is about metadata tracking, not template resolution.

## Verification

- **Build result:** `BUILD SUCCEEDED`
- No warnings or errors introduced.
