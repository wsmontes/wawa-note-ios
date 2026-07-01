# Remaining Issues — Wawa Note mvp-v2

Tracking document for all non-critical issues found during the UX + AI audit loops.
Items are documented here rather than as individual code comments to keep the codebase clean.

## 🔒 Segurança / Resiliência
- **Audio import inconsistency**: deleteItem on failure vs text import keeps form open (HomeView)
- **ProviderEditorView**: no duplicate detection for custom providers
- **No pause timeout**: recording stays paused indefinitely, holding mic hardware
- **No max recording duration**: infinite recording can fill device storage
- **Scan/Photo createItem**: returns [] silently when KnowledgeItem creation fails
- **M4A repair**: cleanupOrphanedRecordings repair doesn't post notification for UI refresh
- **Argument parsing**: drops typed arrays and nested objects in AgentLoop
- **Circuit breaker**: resets on any success, avoiding trigger on intermittent failures
- **Sub-agent**: no structured output contract, parent parses free text

## 🎨 UI/UX pequenos
- **importSourceApp**: always nil → DOCUMENTED: iOS platform limitation (no public API)
- **Swipe actions**: identical for all statuses → ✅ FIXED: Retry swipe added for failed items
- **assignToProject**: navigates away from Inbox → DOCUMENTED: intentional UX (navigates to project)
- **Cloud-fallback Apple**: not selectable as global → DOCUMENTED: needs Settings UI redesign
- **Per-item transcription**: overwrites global → DOCUMENTED: intentional (user explicitly chose engine)
- **Empty provider state**: no CTA → DOCUMENTED: needs onboarding flow (see Architecture section)
- **Explore segment-switch**: preserves nav → DOCUMENTED: SwiftUI TabView limitation
- **Chat overlay dismiss**: without confirmation → DOCUMENTED: needs confirmation dialog during streaming
- **Waveform**: cosmetic sin() math → DOCUMENTED: visual-only indicator, acceptable for level meter
- **calendarEvents**: loads once, never refreshes → DOCUMENTED: add EKEventStore change observer
- **OnThisDay cards**: from iPhone Calendar render as dead taps → ✅ FIXED: nil guard on NavigationLink
- **deletePartialTranscript**: silently swallows errors → DOCUMENTED: best-effort cleanup, error logged
- **Disk space API**: inconsistency → DOCUMENTED: different APIs serve different purposes
- **ProviderAdapter**: maps as promptedJSON → DOCUMENTED: both support native JSON, adapter conservative
- **Default streaming wrapper**: no real streaming → DOCUMENTED: needs provider-specific SSE overrides
- **Tool descriptions**: captured at init → DOCUMENTED: needs dynamic refresh on schema/skill changes
- **Full-text reassignment**: per-token → DOCUMENTED: acceptable for chat, monitor on older devices
- **Item context resolve-away**: → DOCUMENTED: intentional (all items in project share conversation)
- **EmbeddingService**: no cache → DOCUMENTED: reads from disk per call, add LRU for frequent items
- **LocalIntelligence**: misleading name → DOCUMENTED: rename to SemanticSearch or VectorSearch

## ⚙️ Config / Dados (documentados)
- 7 model presets referenced without presets → DOCUMENTED: add presets or update references
- gpt-4o/gpt-4o-mini deprecated 2026-07-23 → DOCUMENTED: remove after deprecation date
- agent feature uses gpt-5-nano → DOCUMENTED: consider upgrading to gpt-5.5 for agents
- Hardcoded $0.002/1K cost → DOCUMENTED: update to per-model pricing
- maxChunkChars double-counts → DOCUMENTED: conservative but safe, reduce margin
- Budget tier cliff at 75% → DOCUMENTED: add intermediate tier at 85%
- OpenRouter ordering hardcoded → DOCUMENTED: add user-configurable provider preferences
- ModelCache TTL 1h → DOCUMENTED: reduce to 15-30min for OpenRouter pricing

## 🏗️ Arquitetura (documentados para redesign)
- ImportError.timeout: never raised → DOCUMENTED: needs watchdog timer in extension
- isIncomplete/importError: never set → DOCUMENTED: needs extension lifecycle hooks
- Partial success: silently swallowed → DOCUMENTED: needs partial-results UI
- Chat citation links: unreachable → DOCUMENTED: needs NavigationStack in overlay
- Disk-full mid-recording: bypasses coordinator → DOCUMENTED: needs audio service callback
- Semantic search results: discarded → DOCUMENTED: needs observable singleton or shell output
- Semantic search toggle: nonexistent → DOCUMENTED: needs InboxView search integration
- System errors: reach user unfiltered → DOCUMENTED: needs ProviderError mapping layer
- Tool call arguments: invisible → DOCUMENTED: needs AgentStatusBar expansion
- Apple cloud fallback: no indicator → DOCUMENTED: needs UI badge on transcription result
- Onboarding flow: entirely missing → DOCUMENTED: needs first-launch welcome + provider setup wizard
- BudgetTracker.recordSpend: ✅ FIXED — wired in all 3 providers
- Anthropic prompt caching: not implemented → DOCUMENTED: 50-90% cost reduction opportunity
- Mode picker (Auto/Deep/Fast): cosmetic → DOCUMENTED: needs separate exec/advisor model pickers
- AIService: orphaned → DOCUMENTED: needs wiring into ProviderRouter or removal
- ModelPolicy.swift: unused → DOCUMENTED: needs wiring into AgentLoop or removal
- Auto-summarize layer 4: not real summary → DOCUMENTED: needs LLM-based summarization
- No output token reservation → DOCUMENTED: needs margin calculation update
- Push-back mechanism: single-iteration → DOCUMENTED: needs persistent push-back in message history
