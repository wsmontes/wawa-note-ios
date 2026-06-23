# Provider Routing & Infrastructure — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-202, KAN-42
**Source modules:** `Providers/`

---

## Overview

Wawa Note supports multiple AI providers through a protocol-first abstraction layer. The routing system selects the best provider for each request based on availability, capability, cost, and user preference. Supporting infrastructure handles API key security, budget enforcement, performance monitoring, resilience, and local network discovery.

---

## Architecture

```
                        ┌──────────────────────┐
                        │   AIConfigService     │
                        │   Model selection     │
                        │   Request params      │
                        │   Feature ceilings    │
                        └──────────┬───────────┘
                                   │
                        ┌──────────▼───────────┐
                        │   ProviderRouter      │
                        │   resolveActive()     │
                        │   resolveBestAvail()  │
                        │   resolveWithFallback │
                        └──────────┬───────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
    ┌─────────▼────────┐ ┌───────▼────────┐ ┌─────────▼────────┐
    │ OpenAICompatible  │ │ Anthropic      │ │ Gemini           │
    │ Provider          │ │ Provider       │ │ Provider         │
    │                   │ │                │ │                  │
    │ • OpenAI          │ │ • Claude Opus  │ │ • Gemini Pro     │
    │ • Ollama          │ │ • Sonnet       │ │ • Gemini Flash   │
    │ • LM Studio       │ │ • Haiku        │ │                  │
    │ • OpenRouter      │ │                │ │                  │
    │ • LocalAI         │ │                │ │                  │
    └───────────────────┘ └────────────────┘ └──────────────────┘

    Supporting Infrastructure:
    ┌─────────────┐ ┌─────────────┐ ┌──────────────┐ ┌─────────────┐
    │ BudgetTracker│ │MetricsTracker│ │CircuitBreaker│ │NetworkMonitor│
    │ Daily limits │ │ Latency/TTFT │ │ Fail threshold│ │ NWPathMonitor│
    └─────────────┘ └─────────────┘ └──────────────┘ └─────────────┘

    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │LocalProvider  │ │ ModelCache   │ │ RetryPolicy  │
    │Scanner        │ │ 1hr TTL      │ │ Exp backoff  │
    │Bonjour+port   │ │ model lists  │ │ with jitter  │
    └──────────────┘ └──────────────┘ └──────────────┘
```

---

## AIProvider Protocol

```swift
protocol AIProvider {
    var id: String { get }
    var displayName: String { get }
    var providerType: ProviderType { get }
    var capabilities: ProviderCapabilities { get }

    func send(_ request: AIRequest) async throws -> AIResponse
    func embed(_ text: String, model: String?) async throws -> [Float]
    func fetchModels() async throws -> [String]
    func fetchModelInfos() async throws -> [ModelInfo]
}

struct ProviderCapabilities {
    let supportsStreaming: Bool
    let supportsJSONMode: Bool
    let supportsFunctionCalling: Bool
    let supportsVision: Bool
    let supportsEmbeddings: Bool
    let maxContextWindow: Int
    let isLocal: Bool
}
```

---

## Provider Implementations

### OpenAICompatibleProvider
**Supports:** OpenAI, Ollama, LM Studio, OpenRouter, LocalAI, any OpenAI-compatible API.

**Configuration:**
- `baseURL` — API endpoint (customizable per service)
- `apiKey` — from Keychain
- `defaultModel` — user-selected model name

**Features:**
- Streaming via SSE (Server-Sent Events)
- JSON mode via `response_format: { type: "json_object" }`
- Function calling via native tools API
- Embeddings via `/v1/embeddings`
- Model list via `/v1/models`

### AnthropicProvider
**Supports:** Claude Opus, Sonnet, Haiku via Anthropic Messages API.

**Features:**
- Streaming via SSE
- Tool use via native tool_use content blocks
- Vision via image content blocks
- Prompt caching via cache_control
- Extended thinking (Opus only)

### GeminiProvider
**Supports:** Gemini Pro, Gemini Flash via Google Generative Language API.

**Features:**
- Streaming via SSE
- JSON mode via response_mime_type
- Function calling via native function_declarations
- Vision via inline_data
- Embeddings via embedding API

---

## ProviderRouter

### Resolution methods

```swift
// 1. Active provider (user-selected)
func resolveActive(context: RequestContext) async throws -> AIProvider
// Returns the user's chosen active provider from settings

// 2. Best available (offline-aware)
func resolveBestAvailable(context: RequestContext) async throws -> AIProvider
// Checks local providers first if offline, then remote

// 3. With fallback
func resolveWithFallback(context: RequestContext) async throws -> AIProvider
// Tries active → best available → first configured → error
```

### Resolution algorithm
1. Check `ActiveProviderManager` for user-selected provider
2. If offline (via `NetworkMonitor`) → prefer local providers (Ollama, LM Studio)
3. If provider has `CircuitBreaker` open → skip, try next
4. If `BudgetTracker` shows provider over daily limit → skip, try next
5. Return resolved provider or throw `ProviderError.noAvailableProvider`

### API key retrieval
Keys stored in Keychain via `SecureKeyStore`:
```
Keychain key: com.wawa-note.provider.<provider_id>
```

---

## ProviderAdapter

Adapts provider-specific API formats to the common `AIRequest`/`AIResponse` model.

**Conversions:**
- OpenAI `messages` array ↔ `AIRequest.messages`
- Anthropic `content` blocks ↔ `AIRequest.messages`
- Gemini `contents` parts ↔ `AIRequest.messages`
- Tool definitions ↔ provider-specific schema format

---

## AIConfigService

Central configuration for AI requests. Enforces:
- **Request params:** temperature, maxTokens per feature + model
- **Reasoning model detection:** sets temperature to nil for o1/o3/thinking models
- **Feature ceiling:** caps maxTokens per feature category (analysis=4096, chat=2048, etc.)
- **Context window:** enforces model-specific limits (8K–200K)

```swift
// Every AI call MUST use:
let params = AIConfigService.shared.requestParams(for: "analysis", model: model)
```

**Feature categories:** `analysis`, `chat`, `transcription`, `embedding`, `title_generation`, `entity_extraction`, `semantic_search`, `vision`

---

## Supporting Infrastructure

### BudgetTracker
Daily spending limits to prevent runaway costs.
- Per-provider daily cap (configurable)
- Per-model daily cap
- Warning threshold at 80%
- Hard stop at 100%
- Reset at midnight UTC
- Persisted to `UserDefaults`

### MetricsTracker / MetricsHistoryStore
Performance monitoring for provider selection.
- **Latency:** time-to-first-token, total response time
- **Tokens/sec:** generation speed
- **Success rate:** rolling 24-hour window
- **Cost per request:** estimated from token counts
- **Daily aggregates:** total tokens, total cost, avg latency
- Persisted to `configs/metrics.json`

### CircuitBreaker
Failure threshold with automatic recovery.
- **Closed:** normal operation
- **Open:** failures > threshold (default: 5 in 60s) → reject requests
- **Half-open:** after recovery time (default: 60s) → allow one probe request
- **Success:** probe succeeds → close circuit
- **Failure:** probe fails → reopen circuit, double recovery time

### NetworkMonitor
NWPathMonitor for connectivity awareness.
- Detects: WiFi, cellular, offline
- Expensive interface detection (cellular)
- Provides `isOnline` for ProviderRouter

### LocalProviderScanner
Discovers local AI services on the LAN.
- **Bonjour/mDNS:** `_ollama._tcp`, `_http._tcp` (LM Studio)
- **Port probe:** `localhost:11434` (Ollama), `localhost:1234` (LM Studio), `localhost:8080` (LocalAI)
- **Result:** provider config ready for one-tap addition
- Runs on app launch and periodically (every 5 min in foreground)

### ModelCache
Caches model lists to avoid repeated API calls.
- **TTL:** 1 hour
- **Per provider:** separate cache entry
- **Invalidation:** on provider config change
- **Storage:** `configs/model_cache.json`

### RetryPolicy
Exponential backoff with jitter for transient failures.
- **Retries:** 3 max
- **Base delay:** 1s
- **Backoff:** ×2 each retry (1s, 2s, 4s)
- **Jitter:** ±25% random variation
- **Non-retryable:** 401 (bad key), 402 (payment required), 403 (forbidden)
- **Retryable:** 429 (rate limit), 5xx (server error), network timeout

---

## Provider Configuration Model

```swift
// SwiftData model
@Model class AIProviderConfigModel {
    var id: UUID
    var displayName: String          // "My OpenAI Account"
    var providerTypeRaw: String      // "openai", "anthropic", "gemini", "openai_compatible"
    var baseURLString: String        // "https://api.openai.com/v1"
    var defaultModel: String         // "gpt-4o"
    var capabilities: String         // JSON-encoded ProviderCapabilities
    var isActive: Bool
    var createdAt: Date
}
```

---

## Provider Discovery UX

### Pre-configured templates
| Template | Base URL | Default Model |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | gpt-4o |
| Anthropic | `https://api.anthropic.com/v1` | claude-sonnet-4-6 |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | gemini-2.5-pro |
| Ollama (local) | `http://localhost:11434/v1` | llama3 |
| LM Studio (local) | `http://localhost:1234/v1` | (auto-detect) |
| OpenRouter | `https://openrouter.ai/api/v1` | (user choice) |

### One-tap connect flow
1. User picks template → base URL and capabilities pre-filled
2. User pastes API key → saved to Keychain
3. "Test Connection" → sends minimal request → success/failure feedback
4. On success → provider appears in active model picker

### Auto-discovery flow
1. LocalProviderScanner finds Ollama/LM Studio on LAN
2. Notification: "Found Ollama on your network"
3. User taps → provider added without typing URLs
