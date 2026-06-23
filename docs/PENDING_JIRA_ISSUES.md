# Pending JIRA Issues — Documentation Sprint

**Created:** 2026-06-22
**Status:** Pending JIRA MCP tool fix
**Tool blocked by:** `jira_create_issue` CLI argument parsing bug — multi-word summaries/descriptions treated as positional arguments

---

These JIRA issues need to be created for undocumented features. Each maps to a gap identified in `DOCUMENTATION_GAP_ANALYSIS.md`.

## P0 — Critical

1. **Document Agent system architecture** — AgentLoop, VFS (15 paths), ShellInterpreter (24 commands), AgentMemoryStore, PromptStore, ToolContext. Priority: Highest. Labels: documentation, sprint:1, P0.

2. **Document Chat block rendering system** — 18 output types with streaming in ChatBlockViews.swift. Priority: Highest. Labels: documentation, sprint:1, P0.

## P1 — High

3. **Document content pipeline state machine** — 11 states, transitions, recovery paths, 8 framework templates. Priority: High. Labels: documentation, sprint:1.

4. **Document barcode/QR scanning** — BarcodeScannerView, 13 symbologies, ScannedCode model. Priority: High. Labels: documentation, sprint:1.

5. **Document Live OCR feature** — LiveOCRView, real-time Vision + Core Motion. Priority: High. Labels: documentation, sprint:1.

6. **Document user journeys** — 8 complete user flows. Priority: High. Labels: documentation, sprint:1. (NOTE: written at docs/USER_JOURNEYS.md)

7. **Document project frameworks** — 5 built-in frameworks, DynamicAnalysis, LensAnalysisService. Priority: High. Labels: documentation, sprint:2.

8. **Document Anarlog sync ecosystem** — 15 files, AnarlogSyncService, EvalSystem, SpeakerLabeler. Priority: High. Labels: documentation, sprint:2.

9. **Document PostRecording automation** — auto-transcribe/analyze flow. Priority: High. Labels: documentation, sprint:1.

10. **Document provider infrastructure** — BudgetTracker, MetricsTracker, CircuitBreaker, NetworkMonitor, LocalProviderScanner, ModelCache, RetryPolicy. Priority: High. Labels: documentation, sprint:2.

## P2 — Medium

11. **Document TrashService** — soft-delete, restore, empty. Priority: Medium. Labels: documentation, sprint:2.

12. **Document ConfigProjectService** — system config via VFS. Priority: Medium. Labels: documentation, sprint:2.

13. **Document ProjectFrame/Snapshot/ChangeRecord** — temporal project models. Priority: Medium. Labels: documentation, sprint:2.

14. **Document SpeechAnalyzerEngine + TranscriptChunker** — speech analysis pipeline. Priority: Medium. Labels: documentation, sprint:2.

15. **Document VoiceActivityDetector integration** — VAD chunking for transcription. Priority: Medium. Labels: documentation, sprint:2.

## Documentation meta-issues

16. **Add DocC catalog** — public protocol documentation. Priority: Medium. Labels: documentation, sprint:3.

17. **Organize docs/ into subdirectories** — architecture/, features/, plans/, guides/. Priority: Low. Labels: documentation, sprint:3.

18. **Promote completed memory files to docs/** — archive stale plans. Priority: Low. Labels: documentation, sprint:3.

---

## Documents created this iteration (2026-06-22)

| Document | Covers |
|---|---|
| `docs/DOCUMENTATION_GAP_ANALYSIS.md` | Feature × docs × JIRA coverage matrix |
| `docs/README.md` | Central documentation index |
| `docs/USER_JOURNEYS.md` | 8 complete user journeys |
| `docs/AGENT_SYSTEM_ARCHITECTURE.md` | Agent system technical spec |
| `CLAUDE.md` (updated) | Added 18+ missing features, expanded module layout |
