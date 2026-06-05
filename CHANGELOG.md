# Changelog

All notable changes to Wawa Note will be documented in this file.

## [1.0.0] — 2026-06-05

### Added
- **Agentic Chat** with shell-based tool calling (single `run_command` replaces 47 individual tools)
- **Shell Virtual Filesystem** — Unix-like commands (`ls`, `cd`, `cat`, `touch`, `echo`, `find`, `grep`, `mv`, `rm`, `head`, `wc`, `history`, `extract`, `js-eval`, `help`)
- **AgentStatusBar** — compact collapsible tool call display
- **Swipe actions** on TaskCardView (Done direct, Details via model) and ItemCardView (Details, Analyze)
- **ChoicePromptView** — numbered options become tappable buttons with visual selection
- **ConfirmationView** with resolution state
- **Contextual suggestion bar** on scroll-up with context-aware chips
- **isInternal flag** on ChatMessage — UI-triggered actions don't create visible bubbles
- **sendInternalMessage** — button decisions sent to agent without input field
- **resolveContext()** — items in projects redirect to project chat context
- **Context injection** — synthetic cd+ls messages with proper ChatBlock rendering
- **Voice dictation** — on-device (Apple Speech) + remote (Whisper API) with permission checks
- **Markdown rendering** via AttributedString (safe: <500 chars)
- **Grouped conversations** in ConversationListView
- **Debug logging** for context propagation
- **Multi-provider greeting** — works with any configured AI provider

### Fixed
- **P0: CheckedContinuation double-resume crash** in ContentPipelineService.processEntry (was 94% of crashes)
- **P0: Gray screen on empty chat** — emptyState now properly centered in GeometryReader
- **P0: Auto-scroll** — changed anchor from `.top` to `.bottom`, added streamingText tracking
- **P0: Error state cleanup** — streamingText and activeToolCalls now cleared on error
- **P0: mv inbox path** — now accepts item titles, not just UUIDs
- **P1: Greeting flash** — eliminated by reordering insertCachedGreeting before streamingText clear
- **P1: Greeting/user message interleaving** — dedicated greetingTask + guards
- **P1: Cancelled stream race condition** — wasCancelled flag prevents phantom messages
- **P1: Partial response loss on context switch** — persisted with [Interrupted] marker
- **P1: Voice dictation** — replaced broken raw PCM with proper AVAudioRecorder .wav format
- **P1: Microphone permission check** — clear error when denied
- **P1: Audio engine release** — proper cleanup on dictation cancel
- **P2: Greeting provider crash** — now uses AIConfigService.requestParams instead of hardcoded model/temperature
- **P2: Infinite pipeline loop** — process() now marks items as analyzed
- **P2: runCommandDirectly messages** — marked as isInternal (no chat clutter)
- **Shell bugs**: ls -la combined flags, ls people/ path, cd trailing slash normalization, inbox title fallback

### Changed
- Replaced 47 individual tool files with single ShellInterpreter + ShellTool
- Redesigned PipelineProgressCardView as thin expandable bar
- Compact AgentStatusBar replaces individual ToolCallCardView cards
- Greeting generation respects active provider and model presets

### Removed
- Deprecated individual tool files: GetItemTool, ListItemsTool, SearchKnowledgeTool, GraphAndTaskTools, ToolFormatting
