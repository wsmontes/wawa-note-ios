# Wawa Note — Migration Guide

## Current version: 1.0 (Build 5)

### Migration flags in UserDefaults

| Flag | Purpose | Version |
|------|---------|---------|
| `migration_field_provenance_v1` | Field-level provenance tracking | 0.9 → 1.0 |
| `migration_meeting_to_audio_done` | KnowledgeItem type rename (meeting→audio) | 0.8 → 0.9 |
| `embeddings_backfill_done_v1` | Semantic embeddings backfill | 0.7 → 0.8 |

### Data model versions

All SwiftData models are versioned via `Schema` and `ModelContainer`. When adding/removing properties:

1. Use optional types for new fields (`String?`, `Int?`, `Bool = false`)
2. Add a migration flag in UserDefaults
3. Run the migration once via `AppDelegate.didFinishLaunching`
4. Set the flag to prevent re-running

### File storage

- Audio files: `Documents/Meetings/{uuid}/segments/segment-NNN.m4a`
- Analysis: `Documents/Meetings/{uuid}/analysis.json`
- Transcript: `Documents/Meetings/{uuid}/transcript.json`
- Config: `Documents/Configs/skills.json`, `prompts.json`, `agent_memories.json`

### Breaking changes to avoid

- Never rename `KnowledgeItem.typeRaw` values without migration
- Never change `AIProviderConfigModel` schema without migration
- Never move or rename `FileArtifactStore` directory structure

### Future migrations planned

- v1.1: Add `Project.templateID` for framework-assigned templates
- v1.2: Add `KnowledgeItem.sourceApplication` for cross-app imports
- v2.0: Entity extraction schema v2 (nested entities)
