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
- **importSourceApp**: always nil (Share Extension never sets it)
- **Swipe actions**: identical for all statuses in InboxView (failed items should show Retry)
- **assignToProject**: navigates away from Inbox (surprising)
- **Cloud-fallback Apple**: not selectable as global default (only per-item)
- **Per-item transcription**: overwrites global TranscriptionSettings as side-effect
- **Empty provider state**: no CTA for first-time users
- **Explore segment-switch**: preserves nav stack (doesn't pop to root)
- **Chat overlay dismiss**: without confirmation during active message
- **Waveform**: cosmetic sin() math, not real audio data
- **calendarEvents**: loads once, never refreshes
- **OnThisDay cards**: from iPhone Calendar render as dead taps
- **deletePartialTranscript**: silently swallows errors
- **Disk space API**: inconsistency between Share Extension (raw) and main app (ImportantUsage)
- **ProviderAdapter**: maps Anthropic/Gemini as promptedJSON (both support native JSON mode)
- **Default streaming wrapper**: no real streaming for OpenAI/Gemini providers
- **Tool descriptions**: captured at init time, don't update mid-session
- **Full-text reassignment**: streamingText = fullContent on every token delta
- **Item context resolve-away**: to project, sharing chat between items
- **EmbeddingService**: no in-memory LRU cache
- **LocalIntelligence**: directory name misleading (no on-device ML)

## ⚙️ Config / Dados (já documentados no ai_config.json)
- 7 model presets referenced in model_policy without presets
- gpt-4o/gpt-4o-mini deprecated 2026-07-23
- agent feature uses gpt-5-nano (weak for agents)
- Hardcoded $0.002/1K cost estimate
- maxChunkChars double-counts output budget
- Budget tier thresholds create abrupt cliff at 75%
- OpenRouter provider ordering hardcoded
- ModelCache TTL 1h high for OpenRouter

## 🏗️ Arquitetura (precisa de redesign)
- ImportError.timeout: defined but never raised in Share Extension
- isIncomplete/importError: never set by Share Extension
- Partial success: silently swallows failures in Share Extension
- Chat citation links: unreachable (overlay without NavigationStack)
- Disk-full mid-recording: bypasses coordinator orchestration
- Semantic search results: discarded (ShellInterpreter never returns them)
- Semantic search toggle: nonexistent in InboxView
- System errors: reach user unfiltered (NSURLError.localizedDescription)
- Tool call arguments: invisible in AgentStatusBar UI
- Apple cloud fallback: happens without user indicator
- Onboarding flow: entirely missing (first-launch users see no guidance)
- BudgetTracker.recordSpend: now wired ✅
- Anthropic prompt caching: not implemented (50-90% cost reduction opportunity)
- Mode picker (Auto/Deep/Fast): cosmetic — doesn't change model, only iterations
- AIService: orphaned architecture (well-designed but never instantiated)
- ModelPolicy.swift: protocol + actor defined but never used
- Auto-summarize layer 4: not real summarization (concatenates 80-char previews)
- No output token reservation in context budget
- Push-back mechanism: single-iteration only
