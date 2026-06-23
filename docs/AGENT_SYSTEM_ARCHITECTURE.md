# Agent System Architecture — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-9, KAN-46, KAN-76, KAN-118, KAN-120
**Source modules:** `Domain/Agent/`, `Domain/Services/ContentPipelineService.swift`

---

## Overview

The Wawa Note agent system lets an LLM interact with the user's knowledge workspace through a virtual filesystem (VFS) and a Unix-inspired shell. The LLM sees the workspace as a filesystem tree and uses shell commands to read, write, search, and analyze content. All tool calls flow through a single `run_command` interface — the ShellTool.

**Key design decisions:**
- **Single tool, 24 commands** instead of 47 individual tools
- **Virtual filesystem** mirrors domain objects (items, projects, tasks) as files and directories
- **Two-phase agent lifecycle**: pipeline (autonomous analysis) and chat (interactive conversation)
- **Model tiering**: executor (cheaper, does the work) + advisor (better, reviews decisions)

---

## Component Architecture

```
┌─────────────────────────────────────────────────────┐
│                    AgentLoop                         │
│  Modes: auto(12) / deep(24) / fast(6)               │
│  Circuit breaker (5 consecutive failures)            │
│  Deadline enforcement                               │
│  Stream heartbeat (30s timeout)                     │
│  Sub-agent spawning                                 │
│  Dynamic model routing (budget-aware)               │
│  Prompt caching (static/dynamic fragments)           │
├─────────────────────────────────────────────────────┤
│  ┌───────────────┐  ┌─────────────────────────────┐ │
│  │   ShellTool    │  │  AgentMemoryStore            │ │
│  │  run_command   │  │  Pattern/strategy learning   │ │
│  └───────┬───────┘  │  Success/fail tracking       │ │
│          │           └─────────────────────────────┘ │
│  ┌───────▼───────────────────────────────────────┐  │
│  │         ShellInterpreter                       │  │
│  │  Tokenizer → Command dispatch → Pipe support   │  │
│  │  24 commands: ls, cd, cat, find, grep, ...     │  │
│  └───────┬───────────────────────────────────────┘  │
│          │                                           │
│  ┌───────▼───────────────────────────────────────┐  │
│  │           VFSService                           │  │
│  │  15 virtual path types                         │  │
│  │  Fuzzy UUID matching                           │  │
│  │  Project matching by name/slug                 │  │
│  │  JSON formatting for all entities              │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  ┌───────────────────────────────────────────────┐  │
│  │           ToolContext                          │  │
│  │  activeProjectID, activeItemID, contextKey     │  │
│  │  activeFramework, activeSchema                 │  │
│  │  planningState: isPlanning, planTaskIDs        │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

---

## AgentLoop

### Modes
| Mode | Iterations | Use Case |
|---|---|---|
| `auto` | 12 | Default — balanced exploration vs cost |
| `deep` | 24 | Complex analysis, multi-step reasoning |
| `fast` | 6 | Quick queries, simple operations |

### Execution
1. Builds context window (system prompt + static cache + dynamic fragment)
2. Calls LLM with tool definitions
3. LLM returns text or tool_use
4. If tool_use: ShellTool.execute() → ShellInterpreter → VFSService
5. Tool result appended to messages, loop continues
6. Circuit breaker: 5 consecutive tool failures → abort
7. Deadline: max 300s wall clock
8. Stream heartbeat: if no token in 30s → abort

### Sub-agent spawning
AgentLoop can spawn sub-agents for focused, parallel work:
- Each sub-agent gets a subset of tools
- Sub-agents run on cheaper models
- Results are merged back into the main context
- Pattern: `run_command` with `--agent` flag

### Dynamic model routing
Based on budget state and mode:
- Normal: executor model for tool calls
- Near budget limit: switch to cheaper model
- Advisor: used for planning/verification phases

### Prompt caching
- Static fragment: system prompt, tool definitions, VFS structure (cached)
- Dynamic fragment: current context, recent messages, active project/item (not cached)

---

## ShellTool (run_command)

The single agent tool: `run_command`

**Parameter:** `command` (string) — the shell command to execute
**Returns:** stdout (success) or stderr (error) + blocks + displaySummary

### Why a shell instead of 47 tools?
- **Composability**: `find inbox -name "*.md" | grep "quarterly" | cat` → pipeline
- **Familiarity**: LLMs understand Unix shells natively
- **Extensibility**: new commands don't need new tool definitions
- **Context efficiency**: one tool schema instead of 47

---

## ShellInterpreter — 24 Commands

### Tokenizer
Lexes the command string into tokens, respecting quoted strings and escape sequences.

### Command dispatcher
Routes to handler based on first token.

### Pipe support
`cat`, `grep`, `wc` support piping via `|`:
- stdout from left command → stdin to right command

### Command Reference

#### Navigation & Listing
| Command | Syntax | Description |
|---|---|---|
| `ls` | `ls [path]` | List directory contents. Paths: root, inbox, projects, project/<name>, project/<name>/items |
| `cd` | `cd <path>` | Change working directory. Affects subsequent relative paths. |

#### Reading & Searching
| Command | Syntax | Description |
|---|---|---|
| `cat` | `cat <file>` | Read file content. Formats: item JSON, transcript, analysis, task details |
| `find` | `find <path> [options]` | Search for items by name, type, date. Supports `--type`, `--since`, `--project` |
| `grep` | `grep <pattern> [file]` | Search within content. Searches transcript, analysis, bodyText |
| `head` | `head <file> [-n N]` | First N lines of a file |
| `wc` | `wc <file>` | Word/line count |

#### Writing & Modification
| Command | Syntax | Description |
|---|---|---|
| `touch` | `touch <path>` | Create item: `touch inbox/item.md --title "..." --type note` |
| `echo` | `echo "text" > <file>` | Write content to a file |
| `rm` | `rm <path>` | Move item to trash |
| `mv` | `mv <source> <dest>` | Move item between directories (e.g., to project) |

#### Analysis & Intelligence
| Command | Syntax | Description |
|---|---|---|
| `analyze` | `analyze <item>` | Run AI analysis pipeline on an item |
| `extract` | `extract <item> [--schema X]` | Extract structured data from content |
| `semantic` | `semantic <query> [--project X]` | Semantic search across items |
| `vision` | `vision <item>` | Analyze image content (OCR, description) |

#### Calendar & People
| Command | Syntax | Description |
|---|---|---|
| `cal` | `cal [date]` | Query calendar events for date/range |
| `person` | `person <name>` | Cross-reference person across Contacts, Calendar, transcripts, call history |

#### Export & Utility
| Command | Syntax | Description |
|---|---|---|
| `export` | `export <item/project> --format md/json/csv` | Export content |
| `history` | `history` | Show recent commands |
| `progress` | `progress` | Show processing queue status |
| `cleanup` | `cleanup` | Remove temporary files, clear caches |
| `describe` | `describe <path>` | Show metadata about a path (type, size, dates) |
| `recipe` | `recipe <name>` | Load and execute a saved recipe (command sequence) |
| `help` | `help [command]` | Show command help |
| `ask_user` | `ask_user "question"` | Ask the user a question (pauses agent, shows UI prompt) |

---

## VFSService — Virtual Filesystem

### Path Types (15)
| Path | Maps To | Example |
|---|---|---|
| `/root` | Root of VFS | `ls /root` |
| `/inbox` | All items not in a project | `ls /inbox` |
| `/inbox/<uuid>` | Specific item by UUID | `cat /inbox/abc123` |
| `/projects` | All projects | `ls /projects` |
| `/projects/<name>` | Project by name/slug | `ls /projects/my-project` |
| `/projects/<name>/items` | Items in project | `ls /projects/my-project/items` |
| `/projects/<name>/items/<uuid>` | Specific item in project | `cat .../items/abc123` |
| `/projects/<name>/tasks` | Tasks in project | `ls .../tasks` |
| `/projects/<name>/tasks/<id>` | Specific task | `cat .../tasks/task-1` |
| `/projects/<name>/people` | People linked to project | `ls .../people` |
| `/projects/<name>/edges` | Graph edges in project | `ls .../edges` |
| `/projects/<name>/signals` | AgentSuggestion signals | `ls .../signals` |
| `/projects/<name>/analysis` | Project synthesis | `cat .../analysis` |
| `/projects/<name>/export` | Export directory | `export ...` |
| `/agent/prompts` | Editable prompt templates | `cat /agent/prompts/analysis` |
| `/agent/memories` | Learned patterns | `ls /agent/memories` |
| `/config/providers` | AI provider configs | `ls /config/providers` |
| `/config/settings` | App settings | `cat /config/settings` |
| `/config/schemas` | Framework schemas | `ls /config/schemas` |

### Operations
- **read(path)** → formatted string (JSON for entities, markdown for content)
- **write(path, content)** → create or update
- **delete(path)** → trash item or delete file
- **move(source, dest)** → move between directories
- **list(path)** → directory listing with metadata

### Smart matching
- UUIDs matched fuzzily (prefix matching, case-insensitive)
- Projects matched by name or slug (case-insensitive, partial match)
- Filenames sanitized for VFS compatibility

---

## ToolContext

Mutable context shared across all tool executions within an AgentLoop session:

```swift
struct ToolContext {
    var activeProjectID: UUID?
    var activeProjectSlug: String?
    var activeProjectName: String?
    var activeItemID: UUID?
    var contextKey: String?          // ChatContext key
    var sandboxedItemID: UUID?      // Restricted scope
    var activeFramework: String?    // e.g., "meeting", "research"
    var activeSchema: String?       // Custom JSON schema
    var isPlanning: Bool
    var planTaskIDs: [String]
    var planCreatedAt: Date?
}
```

### Lifecycle
1. Created at AgentLoop start
2. `activeProjectID` set when user has a project context open
3. `sandboxedItemID` restricts agent to single item during pipeline analysis
4. `activeFramework` set by SelectSchemaTool
5. Planning state tracks when agent is in plan-then-execute mode

---

## AgentMemoryStore

Learns from agent successes and failures. Persisted as JSON.

### What it tracks
- Successful command patterns → weight increased
- Failed commands → pattern recorded, suggested alternatives
- Per-project patterns → scoped learning
- Strategy effectiveness → which approaches work for which task types

### Storage
`FileArtifactStore.baseURL/configs/agent_memory.json`

---

## PromptStore

Editable prompt templates loaded from `ai_config.json` and overridable through the VFS.

### Override chain
1. Bundle default (`ai_config.json`)
2. User overrides (`configs/prompts/`)
3. Per-project overrides (`configs/prompts/<project_slug>/`)

### Key templates
- `system` — main system prompt
- `analysis` — meeting analysis instructions
- `planning` — plan-before-execute prompt
- `synthesis` — project synthesis instructions
- `chat` — conversational chat prompt

---

## Pipeline Agent Tools

Used exclusively by ContentPipelineService during autonomous item analysis (not available in chat).

| Tool | Purpose |
|---|---|
| `SetTitleTool` | Renames the item based on content analysis |
| `SelectSchemaTool` | Chooses analysis schema (meeting, research, etc.) |
| `SelectSkillTool` | Selects analysis skill template |
| `WriteAnalysisTool` | Saves structured analysis JSON with rollback |
| `WriteSpeakersTool` | Saves speaker diarization results |

### WriteAnalysisTool rollback (KAN-76)
Partial JSON writes are detected and rolled back:
1. Write to temp file first
2. Validate JSON on temp file
3. Only move to final location on success
4. On failure → keep previous analysis intact

---

## Project Agent Tools

Available in both pipeline and chat contexts.

| Tool | Purpose |
|---|---|
| `SynthesizeProjectTool` | Saves project synthesis (markdown, sections, metrics) |
| `EmitSignalTool` | Creates risk/alert/opportunity/doubt/pattern/contradiction signals |
| `CreateConnectionTool` | Creates typed graph edges between items |
| `RequestReprocessTool` | Marks items for re-analysis |

### Signal types (EmitSignalTool)
- `risk` — potential problem
- `alert` — immediate attention needed
- `opportunity` — positive pattern to explore
- `doubt` — low-confidence finding
- `pattern` — recurring theme across items
- `contradiction` — conflicting information

---

## ContentParser

Heuristic markdown → structured blocks parser. Runs on LLM output before rendering.

### Block types detected
- Tables (pipe-delimited)
- Code blocks (``` fences)
- Bullet lists
- Ordered lists
- Action items (`- [ ]`)
- Decision records (`**Decision:**`)
- Key-value pairs

---

## AgentTool Protocol

```swift
protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: AIToolParameters { get }  // JSON Schema
    func execute(_ arguments: [String: Any], context: ToolContext) async throws -> ToolResult
    func validateArguments(_ arguments: [String: Any]) throws
}

struct ToolResult {
    let content: String
    let blocks: [ChatBlock]?
    let citations: [Citation]?
    let isError: Bool
    let displaySummary: String?
}
```

### AgentToolRegistry
- Name-indexed map of all registered tools
- Generates `AIToolDefinition` array for LLM API
- Validates tool availability before execution

---

## ContextWindowManager

Message truncation for token budget management:
- Calculates token counts for messages
- Truncates oldest messages when nearing context limit
- Preserves system prompt and most recent messages
- Respects model-specific context windows (8K–200K)

---

## Integration Points

### Chat integration (ChatViewModel → AgentLoop)
```
ChatViewModel.sendMessage()
  → AgentLoop.runStreaming()
    → LLM API call
    → tool_use → ShellInterpreter → VFSService
    → streaming tokens → ChatBlockViews
  → ChatService.appendMessages()
```

### Pipeline integration (ContentPipelineService → AgentLoop)
```
ContentPipelineService.process()
  → AgentLoop.runAutonomous()
    → SelectSchema → WriteAnalysis → SynthesizeProject
    → ProjectIngestionPipeline.ingest()
  → KnowledgeItem status: analyzed
```

---

## Performance Characteristics

| Metric | Value |
|---|---|
| AgentLoop startup | ~200ms (prompt cache hit) |
| Command execution | 50-500ms (depends on I/O) |
| Tool call round-trip | 1-5s (LLM latency) |
| Pipeline analysis (auto mode) | 30-120s |
| Chat response (fast mode) | 5-15s |
| Max commands per session | Unlimited (within mode iterations) |
| Memory footprint | ~50MB (context window + VFS state) |
