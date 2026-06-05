<p align="center">
  <img src="docs/assets/logo-horizontal.png" width="400" alt="Wawa Note">
</p>

<p align="center">
  <strong>Local-first AI workspace for project memory. iOS. Provider-agnostic.</strong>
</p>

<p align="center">
  <a href="https://github.com/wsmontes/wawa-note-ios/releases"><img src="https://img.shields.io/github/v/release/wsmontes/wawa-note-ios?color=blue" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-iOS%2017%2B-orange" alt="Platform: iOS 17+">
  <img src="https://img.shields.io/badge/Swift-6.0%20%7C%20SwiftUI-purple" alt="Swift 6.0 | SwiftUI">
  <a href="https://github.com/wsmontes/wawa-note-ios/actions"><img src="https://img.shields.io/badge/CI-GitHub%20Actions-blue" alt="CI"></a>
</p>

---

## What is Wawa Note?

Wawa Note captures meeting evidence — audio recordings, scanned documents, web links, notes — and transforms them into a **canonical project knowledge store** with typed graph relationships, tasks, decisions, and provenance trails. An agentic AI chat with tool calling lets you query, navigate, and act on your knowledge without switching contexts.

**No backend. No vendor lock-in. Your data stays on your iPhone.**

### Core Capabilities

- **Capture Anything**: Record meetings (audio + transcription), scan documents (VisionKit OCR), save web bookmarks, write notes
- **Intelligent Pipeline**: Extract → Analyze → Detect signals → Ingest — fully automated per item
- **Agentic Chat**: AI agent with shell-based tool calling navigates your knowledge like a filesystem
- **Project Graph**: Typed relationships between items, tasks, people, and decisions — all with evidence provenance
- **Provider Agnostic**: Works with OpenAI, Anthropic, Gemini, DeepSeek, OpenAI-compatible APIs, and local models
- **Privacy First**: All data stored locally. Audio, transcripts, and analysis stay on device

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    iOS App (SwiftUI)                      │
│  Capture │ Inbox │ Explore │ Chat │ Settings              │
├──────────────────────────────────────────────────────────┤
│                    Domain Layer                           │
│  Agent (Shell VFS + Tool Calling) │ Content Pipeline      │
│  Project Models │ Graph │ Calendar │ Search               │
├──────────────────────────────────────────────────────────┤
│                    Provider Abstraction                   │
│  OpenAI │ Anthropic │ Gemini │ DeepSeek │ Local LLM       │
├──────────────────────────────────────────────────────────┤
│                    Storage                                │
│  SwiftData (metadata) │ FileManager (artifacts)            │
│  Keychain (API keys)  │ Spotlight (indexing)              │
└──────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Shell VFS for tool calling**: Instead of dozens of individual AI tools, the agent uses a single `run_command` with Unix-like shell commands (`ls`, `cd`, `cat`, `touch`, `echo`, `find`, `grep`, etc.). This makes the agent more flexible and reduces tool maintenance overhead.
- **Protocol-first boundaries**: Every external dependency (AI providers, transcription engines, import/export formats) is behind a Swift protocol.
- **No backend**: The app is fully local. No servers, no cloud sync, no accounts.
- **Provenance on every edge**: Graph relationships are traceable to a transcript segment, note block, or external event.

---

## Quick Start

### Requirements

- Xcode 16+
- iOS 17.0+
- iPhone (or iPad / Mac with Catalyst)
- An API key for at least one AI provider

### Setup

```bash
git clone https://github.com/wsmontes/wawa-note-ios.git
cd wawa-note-ios
open wawa-note.xcodeproj
```

1. Open the project in Xcode
2. Select your development team in Signing & Capabilities
3. Build and run (Cmd+R) on a device or simulator
4. Go to Settings → Provider → Add your API key

### Provider Configuration

Wawa Note works with **any** AI provider. Configure in Settings:

| Provider | What You Need |
|----------|---------------|
| **OpenAI** | API key + base URL (default: `https://api.openai.com/v1`) |
| **Anthropic** | API key + base URL |
| **Gemini** | API key + base URL |
| **DeepSeek** | API key + base URL |
| **OpenAI-compatible** | API key + your own endpoint (Ollama, vLLM, Groq, etc.) |
| **Local LLM** | Endpoint URL only (e.g., `http://localhost:8080/v1`) |

All providers are configured via `wawa-note/Providers/ai_config.json` — add new models, adjust context windows, or mark reasoning models.

---

## Features

### Capture
- **Audio recording** with on-device (Apple Speech) or remote (Whisper API) transcription
- **Document scanning** via VisionKit (multi-page OCR)
- **Note creation** with markdown support
- **Web bookmarks** and **file import** (JSON, Markdown, ICS, SRT, PDF, HTML, RTF)
- **Share Extension** — send content directly from any app

### Agentic Chat
- **Shell-based tool calling** — the AI navigates your knowledge like a filesystem
- **Context-aware conversations** — chats are scoped to projects, items, or global
- **Auto/Deep/Fast modes** — control how much the agent iterates
- **Voice input** via on-device speech recognition or Whisper
- **Swipe actions** on task/item cards for quick status changes
- **Choice prompts** — numbered options become tappable buttons
- **Markdown rendering** in messages
- **Suggestion bar** on scroll-up with context-aware prompts

### Project Intelligence
- **Task boards** with status, priority, owner tracking
- **Graph view** — typed relationships with evidence provenance
- **Timeline** — calendar integration with day summaries
- **Project health** metrics and signals
- **Flexible frameworks** — LLM-defined schemas for project structure

### iOS Integrations
- Calendar read/write + context sensor
- Reminders export
- Core Spotlight indexing
- Face ID biometric gate
- Live Activities during recording
- Watch Connectivity (companion app)

---

## Project Structure

```
wawa-note/
├── App/                    # App entry point
├── Audio/                  # Recording, playback, session management
├── Connectivity/           # Watch, recording coordinator
├── ContextCapture/         # Calendar, location, focus, motion sensors
├── Domain/
│   ├── Agent/              # AgentLoop, ShellInterpreter, ShellTool, ToolContext
│   ├── Calendar/           # Calendar sync, timeline, day summaries
│   ├── Models/             # KnowledgeItem, Project, Task, Person, GraphEdge, Chat
│   └── Services/           # Content pipeline, search, project services
├── Ecosystem/
│   ├── Export/             # Markdown, JSON, SRT, CSV, Graph exporters
│   ├── Import/             # 10 format importers + import router
│   └── Spotlight/          # Core Spotlight indexing
├── LocalIntelligence/      # Embeddings, semantic search
├── Providers/              # AIProvider protocol + OpenAI, Anthropic, Gemini adapters
├── Security/               # Biometric gate, secure keychain
├── Storage/                # File artifact store, keychain wrapper
├── Transcription/          # Apple Speech + remote transcription engines
├── UI/                     # All SwiftUI views
│   ├── Capture/            # Scanner, recording UI
│   ├── Chat/               # Chat view, blocks, parser, view model
│   ├── Components/         # ContentView, shared components
│   ├── Explore/            # Project explorer
│   ├── Inbox/              # Universal search + triage
│   ├── Knowledge/          # Item detail, connections
│   ├── Project/            # Project detail, timeline, graph, tasks
│   └── Settings/           # Provider picker, config
└── Utilities/              # Logging, design tokens
```

---

## Configuration

### AI Providers (`Providers/ai_config.json`)

The AI config file defines available providers, models, presets, and feature configurations:

```json
{
  "modelPresets": {
    "claude-sonnet-4-6": {
      "contextWindow": 200000,
      "maxOutputTokens": 64000,
      "reasoningModel": false,
      "supportsTemperature": true
    }
  },
  "features": {
    "chat": {
      "defaultModel": "claude-sonnet-4-6",
      "temperature": 0.7
    }
  }
}
```

### Permissions

Wawa Note requests these permissions on first use:
- **Microphone** — for audio recording
- **Speech Recognition** — for on-device transcription
- **Camera** — for document scanning
- **Calendar** — for calendar integration
- **Location** — for context sensing (optional)
- **Notifications** — for Live Activities (optional)

All permissions are optional. The app works without them with reduced functionality.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to contribute.

- **Architecture decisions**: [docs/DECISIONS.md](docs/DECISIONS.md)
- **Coding standards**: [docs/CODING_STANDARDS.md](docs/CODING_STANDARDS.md)
- **Security policy**: [SECURITY.md](SECURITY.md)

### Development Principles

1. Protocol-first boundaries — every integration is behind a protocol
2. No hardcoded API keys, provider URLs, or secrets
3. Use Keychain for API keys, FileManager for artifacts, SwiftData for metadata
4. Keep SwiftUI views thin — services should be testable without UI
5. Use `AIConfigService.shared.requestParams(for:model:)` for ALL AI requests
6. Do not put provider-specific JSON across the app

---

## License

MIT — see [LICENSE](LICENSE) for details.

Wawa Note is **provider-agnostic** and does not bundle any AI provider SDKs. Provider integrations are implemented against public REST APIs.

---

<p align="center">
  <sub>Built with ❤️ by <a href="https://github.com/wsmontes">@wsmontes</a> and contributors</sub>
</p>
