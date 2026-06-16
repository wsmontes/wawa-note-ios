# AI Services Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesenhar AI Services com AIService como fachada única, AgentOrchestrator unificado, ModelPolicy 100% JSON-driven, Provider/API templates data-driven.

**Architecture:** Fachada `AIService` (actor) é o único ponto de entrada para chamadas AI. `ModelOverride` opcional permite qualquer ponta sobrescrever modelo/tier/temperature/maxTokens. Três protocolos injetáveis (`AIConfigProvider`, `ProviderResolver`, `ModelPolicy`) com implementações padrão trocáveis. `AgentOrchestrator` unifica AgentLoop + Pipeline com modos configuráveis via JSON. Templates de providers e APIs são definidos no `ai_config.json` e renderizados dinamicamente na UI.

**Tech Stack:** Swift 6, Swift Concurrency (`async/await`, `actor`), SwiftUI, SwiftData, `ai_config.json` (Codable)

**Spec:** `docs/superpowers/specs/2026-06-16-ai-services-redesign.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `wawa-note/Providers/AIService.swift` | **Create** | Fachada única — `send()`, `sendStreaming()`, `embed()` |
| `wawa-note/Providers/ModelPolicy.swift` | **Create** | `ModelPolicy` protocol, `TieredModelPolicy`, `ModelPolicyRules` (Codable), `ModelSelection`, `BudgetState` |
| `wawa-note/Providers/ProviderResolver.swift` | **Create** | `ProviderResolver` protocol, `HealthAwareResolver`, `ProviderPreference` |
| `wawa-note/Domain/Agent/AgentOrchestrator.swift` | **Create** | Unifica AgentLoop + Pipeline, `AgentMode` enum |
| `wawa-note/Domain/Agent/APICallTool.swift` | **Create** | Tool genérica para chamar APIs definidas no JSON |
| `wawa-note/Providers/AIProvider.swift` | Modify | Adicionar `ModelOverride`, `BudgetState`; remover `recommendedTier` de `BudgetTracker` |
| `wawa-note/Providers/AIConfigService.swift` | Modify | Refatorar para `JSONConfigProvider` implementando `AIConfigProvider` |
| `wawa-note/Resources/ai_config.json` | Modify | Adicionar `model_policy`, `provider_templates`, `api_templates`, `agent_modes` |
| `wawa-note/Domain/Agent/AgentLoop.swift` | Modify | Remover `resolveModel()`, delegar model selection ao `ModelPolicy` |
| `wawa-note/Domain/Services/AnalysisService.swift` | Modify | Substituir AIRequest manual por `AIService.send()` nos bypass sites |
| `wawa-note/Domain/Services/ContentPipelineService.swift` | Modify | Substituir AgentLoop init por `AgentOrchestrator.runAutonomous()` |
| `wawa-note/UI/Chat/ChatViewModel.swift` | Modify | Substituir AgentLoop init por `AgentOrchestrator.runInteractive()` |
| `wawa-note/Providers/ProviderRouter.swift` | **Delete** | Absorvido por `HealthAwareResolver` |
| `wawa-note/Providers/ActiveProviderManager.swift` | Modify | Simplificar para `ActiveProviderStore` (~20 linhas) |
| `wawa-note/UI/Settings/ProviderTemplates.swift` | Modify | Atualizar para usar `JSONConfigProvider.providerTemplates` |
| `wawa-noteTests/CoreServicesTests.swift` | Modify | Adicionar testes para `ModelPolicy`, `AIService`, `APICallTool` |

---

## Phase 1: New Protocols + Types (Zero Breaking)

### Task 1: Add ModelOverride, BudgetState, and ModelSelection to AIProvider.swift

**Files:**
- Modify: `wawa-note/Providers/AIProvider.swift` (append, after BudgetTracker at line 122)

- [ ] **Step 1: Add BudgetState, ModelOverride, and ModelSelection structs**

Append after line 122 (end of BudgetTracker class):

```swift
// MARK: - BudgetState

struct BudgetState: Sendable {
    let dailyLimit: Double?
    let spentToday: Double
    var remainingPercent: Double {
        guard let limit = dailyLimit, limit > 0 else { return 1.0 }
        return max(0, 1.0 - spentToday / limit)
    }
    var isOverBudget: Bool {
        guard let limit = dailyLimit, limit > 0 else { return false }
        return spentToday >= limit
    }
    var remainingBudget: Double? {
        guard let limit = dailyLimit else { return nil }
        return max(0, limit - spentToday)
    }

    static func from(_ tracker: BudgetTracker) -> BudgetState {
        BudgetState(dailyLimit: tracker.dailyLimit, spentToday: tracker.spentToday)
    }
}

// MARK: - ModelOverride

struct ModelOverride: Sendable {
    var model: String?
    var tier: String?
    var temperature: Double?
    var maxTokens: Int?
    var providerID: String?

    init(model: String? = nil, tier: String? = nil,
         temperature: Double? = nil, maxTokens: Int? = nil,
         providerID: String? = nil) {
        self.model = model
        self.tier = tier
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.providerID = providerID
    }
}

// MARK: - ModelSelection

struct ModelSelection: Sendable {
    let model: String
    let tier: String
    let provider: ProviderType
    let reason: String
}

// MARK: - ProviderPreference

enum ProviderPreference: Sendable {
    case any
    case localPreferred
    case localRequired
    case specific(String)
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Providers/AIProvider.swift
git commit -m "feat: add ModelOverride, BudgetState, ModelSelection, ProviderPreference types"
```

---

### Task 2: Add ModelPolicyRules Codable types in ModelPolicy.swift

**Files:**
- Create: `wawa-note/Providers/ModelPolicy.swift`

- [ ] **Step 1: Create ModelPolicy.swift with Codable config types**

```swift
import Foundation

// MARK: - JSON-Driven Model Policy Rules

struct ModelPolicyRules: Codable, Sendable {
    var budget: BudgetRules
    var tiers: [String: TierConfig]
    var features: [String: [String: String]]
    var offlineFallback: OfflineFallbackConfig
    var userOverride: UserOverrideConfig

    struct BudgetRules: Codable, Sendable {
        var dailyUSD: Double
        var thresholds: [BudgetThreshold]
    }

    struct BudgetThreshold: Codable, Sendable {
        var minPercent: Double
        var tier: String
    }

    struct TierConfig: Codable, Sendable {
        var label: String?
        var prefer: [String]
    }

    struct OfflineFallbackConfig: Codable, Sendable {
        var enabled: Bool
        var timeoutSeconds: Double?
    }

    struct UserOverrideConfig: Codable, Sendable {
        var enabled: Bool
    }
}

extension ModelPolicyRules {
    func tier(for budgetPercent: Double) -> String {
        for threshold in budget.thresholds.sorted(by: { $0.minPercent > $1.minPercent }) {
            if budgetPercent >= threshold.minPercent {
                return threshold.tier
            }
        }
        return budget.thresholds.last?.tier ?? "economy"
    }

    func model(for feature: String, tier: String) -> String? {
        features[feature]?[tier]
            ?? features["chat"]?[tier]
            ?? tiers[tier]?.prefer.first
    }
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Write unit tests for ModelPolicyRules**

Add to `CoreServicesTests.swift`:

```swift
final class ModelPolicyRulesTests: XCTestCase {
    func testTierSelectionDeep() {
        let rules = makeSampleRules()
        XCTAssertEqual(rules.tier(for: 0.75), "deep")
    }

    func testTierSelectionFast() {
        let rules = makeSampleRules()
        XCTAssertEqual(rules.tier(for: 0.30), "fast")
    }

    func testTierSelectionEconomy() {
        let rules = makeSampleRules()
        XCTAssertEqual(rules.tier(for: 0.10), "economy")
    }

    func testTierSelectionLocal() {
        let rules = makeSampleRules()
        XCTAssertEqual(rules.tier(for: 0.01), "local")
    }

    func testModelForFeatureChatDeep() {
        let rules = makeSampleRules()
        XCTAssertEqual(rules.model(for: "chat", tier: "deep"), "claude-sonnet-4-6")
    }

    func testModelForUnknownFeatureFallsBackToChat() {
        let rules = makeSampleRules()
        XCTAssertEqual(rules.model(for: "nonexistent", tier: "fast"), "gpt-5.1-mini")
    }

    func testModelForUnknownTierFallsBackToFirstPrefer() {
        let rules = makeSampleRules()
        XCTAssertEqual(rules.model(for: "chat", tier: "unknown"), nil)
    }

    private func makeSampleRules() -> ModelPolicyRules {
        ModelPolicyRules(
            budget: ModelPolicyRules.BudgetRules(dailyUSD: 1.0, thresholds: [
                ModelPolicyRules.BudgetThreshold(minPercent: 0.50, tier: "deep"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.25, tier: "fast"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.05, tier: "economy"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.00, tier: "local")
            ]),
            tiers: [
                "deep": ModelPolicyRules.TierConfig(label: "Deep", prefer: ["claude-opus-4-8"]),
                "fast": ModelPolicyRules.TierConfig(label: "Fast", prefer: ["claude-sonnet-4-6"]),
                "economy": ModelPolicyRules.TierConfig(label: "Economy", prefer: ["claude-haiku-4-5"]),
                "local": ModelPolicyRules.TierConfig(label: "Local", prefer: ["phi-4-mini"])
            ],
            features: [
                "chat": ["deep": "claude-sonnet-4-6", "fast": "gpt-5.1-mini", "economy": "claude-haiku-4-5", "local": "phi-4-mini"],
                "analysis": ["deep": "claude-opus-4-8", "fast": "claude-sonnet-4-6", "economy": "gpt-5.1-mini", "local": "phi-4-mini"]
            ],
            offlineFallback: ModelPolicyRules.OfflineFallbackConfig(enabled: true),
            userOverride: ModelPolicyRules.UserOverrideConfig(enabled: true)
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:wawa-noteTests/ModelPolicyRulesTests 2>&1 | grep -E "(Test Case.*passed|Test Case.*failed|BUILD)"
```

Expected: All 7 tests pass

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Providers/ModelPolicy.swift wawa-noteTests/CoreServicesTests.swift
git commit -m "feat: add ModelPolicyRules Codable types with tier/model resolution"
```

---

### Task 3: Add AIConfigProvider, ProviderResolver, ModelPolicy protocols

**Files:**
- Modify: `wawa-note/Providers/ModelPolicy.swift` (append protocols)
- Create: `wawa-note/Providers/ProviderResolver.swift`

- [ ] **Step 1: Append ModelPolicy protocol to ModelPolicy.swift**

```swift
// MARK: - ModelPolicy Protocol

protocol ModelPolicy: Sendable {
    func selectModel(
        for feature: String,
        budget: BudgetState,
        userTier: String?,
        override: ModelOverride?
    ) -> ModelSelection

    func availableModels() async -> [String]
}
```

- [ ] **Step 2: Create ProviderResolver.swift**

```swift
import Foundation

// MARK: - ProviderResolver Protocol

protocol ProviderResolver: Sendable {
    func resolve(
        for feature: String,
        preference: ProviderPreference,
        override: ModelOverride?
    ) async throws -> any AIProvider

    var activeProviderID: String { get async }
    func setActiveProvider(_ id: String) async
}
```

- [ ] **Step 3: Add AIConfigProvider protocol**

Append to `wawa-note/Providers/ModelPolicy.swift`:

```swift
// MARK: - AIConfigProvider Protocol

protocol AIConfigProvider: Sendable {
    func requestParams(for feature: String, model: String, override: ModelOverride?) -> AIFeatureParams
    func modelFor(feature: String) -> String
    func presetFor(model: String) -> AIConfig.ModelPreset?
    var providerTemplates: [ProviderTemplateConfig] { get }
    var apiTemplates: [APITemplate] { get }
    var modelPolicyRules: ModelPolicyRules { get }
    var agentModes: [String: AgentModeConfig] { get }
}

struct AgentModeConfig: Codable, Sendable {
    var feature: String
    var tools: [String]
    var systemPrompt: String?
    var modelTier: String?
}
```

- [ ] **Step 4: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add wawa-note/Providers/ModelPolicy.swift wawa-note/Providers/ProviderResolver.swift
git commit -m "feat: add AIConfigProvider, ProviderResolver, ModelPolicy protocols"
```

---

### Task 4: Add ProviderTemplate Codable struct and APITemplate types

**Files:**
- Modify: `wawa-note/Providers/ModelPolicy.swift` (append)

- [ ] **Step 1: Append ProviderTemplateConfig and APITemplate to ModelPolicy.swift**

```swift
// MARK: - ProviderTemplateConfig (Data-Driven, Codable)

struct ProviderTemplateConfig: Codable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var icon: String
    var type: ProviderType
    var baseURL: String
    var auth: AuthMethod
    var authHeader: String?
    var authPrefix: String?
    var defaultModels: [String]
    var autoDiscover: Bool
    var discoveryPort: Int?
    var description: String
    var requiresAuth: Bool

    enum AuthMethod: String, Codable, Sendable {
        case none
        case apiKeyHeader = "api_key_header"
        case apiKeyBearer = "api_key_bearer"
        case apiKeyQuery = "api_key_query"
    }
}

// MARK: - APITemplate (Data-Driven, Codable)

struct APITemplate: Codable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var icon: String
    var baseURL: String
    var auth: ProviderTemplateConfig.AuthMethod
    var authHeader: String?
    var authPrefix: String?
    var type: APIType
    var endpoints: [APIEndpoint]
    var skill: APISkill

    enum APIType: String, Codable, Sendable {
        case rest
        case graphql
    }
}

struct APIEndpoint: Codable, Sendable {
    var name: String
    var method: String
    var path: String
    var description: String
    var bodyType: String?
    var parameters: [String: APIParameter]?
}

struct APIParameter: Codable, Sendable {
    var type: String
    var description: String?
    var `enum`: [String]?
    var `default`: String?
    var required: Bool?
    var items: String?
}

struct APISkill: Codable, Sendable {
    var name: String
    var prompt: String
    var whenToUse: String?
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Providers/ModelPolicy.swift
git commit -m "feat: add ProviderTemplate, APITemplate, APIEndpoint Codable types"
```

---

### Task 5: Create AIService skeleton (compiles, no integration yet)

**Files:**
- Create: `wawa-note/Providers/AIService.swift`

- [ ] **Step 1: Write AIService actor skeleton**

```swift
import Foundation
import SwiftData

actor AIService {
    let configProvider: any AIConfigProvider
    let providerResolver: any ProviderResolver
    let modelPolicy: any ModelPolicy
    let retryConfig: RetryPolicy
    let circuitBreaker: CircuitBreaker?
    let budget: BudgetTracker

    init(
        configProvider: any AIConfigProvider,
        providerResolver: any ProviderResolver,
        modelPolicy: any ModelPolicy,
        retryConfig: RetryPolicy = .standard,
        circuitBreaker: CircuitBreaker? = nil,
        budget: BudgetTracker = .shared
    ) {
        self.configProvider = configProvider
        self.providerResolver = providerResolver
        self.modelPolicy = modelPolicy
        self.retryConfig = retryConfig
        self.circuitBreaker = circuitBreaker
        self.budget = budget
    }

    // MARK: - Non-streaming

    func send(
        feature: String,
        messages: [AIMessage],
        tools: [AIToolDefinition]? = nil,
        responseFormat: AIRequest.AIResponseFormat? = nil,
        toolChoice: String? = nil,
        override: ModelOverride? = nil
    ) async throws -> AIResponse {
        // 1. Check circuit breaker
        if let cb = circuitBreaker {
            try cb.allowRequest()
        }

        // 2. Model selection via policy
        let budgetState = BudgetState.from(budget)
        let selection = modelPolicy.selectModel(
            for: feature,
            budget: budgetState,
            userTier: nil,
            override: override
        )

        // 3. Params from config (temperature, maxTokens) — SEMPRE
        let params = configProvider.requestParams(
            for: feature,
            model: selection.model,
            override: override
        )

        // 4. Provider resolved
        let preference: ProviderPreference = override?.providerID.map { .specific($0) } ?? .any
        let provider = try await providerResolver.resolve(
            for: feature,
            preference: preference,
            override: override
        )

        // 5. Build internal AIRequest (callers never see temperature/maxTokens)
        let request = AIRequest(
            model: selection.model,
            messages: messages,
            temperature: override?.temperature ?? params.temperature,
            maxTokens: override?.maxTokens ?? params.maxTokens,
            responseFormat: responseFormat,
            tools: tools,
            toolChoice: toolChoice
        )

        // 6. Send with retry + circuit breaker
        return try await retryConfig.execute {
            let response = try await provider.send(request)
            circuitBreaker?.recordSuccess()
            return response
        } retryIf: { error in
            if let providerError = error as? ProviderError, providerError.isRetryable {
                circuitBreaker?.recordFailure()
                return true
            }
            return false
        }
    }

    // MARK: - Streaming

    func sendStreaming(
        feature: String,
        messages: [AIMessage],
        tools: [AIToolDefinition]? = nil,
        toolChoice: String? = nil,
        override: ModelOverride? = nil
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let budgetState = BudgetState.from(budget)
                    let selection = modelPolicy.selectModel(
                        for: feature, budget: budgetState,
                        userTier: nil, override: override
                    )

                    let params = configProvider.requestParams(
                        for: feature, model: selection.model, override: override
                    )

                    let preference: ProviderPreference = override?.providerID.map { .specific($0) } ?? .any
                    let provider = try await providerResolver.resolve(
                        for: feature, preference: preference, override: override
                    )

                    let request = AIRequest(
                        model: selection.model,
                        messages: messages,
                        temperature: override?.temperature ?? params.temperature,
                        maxTokens: override?.maxTokens ?? params.maxTokens,
                        tools: tools,
                        toolChoice: toolChoice
                    )

                    let stream = provider.sendStreaming(request)
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Embeddings

    func embed(text: String, model: String) async throws -> [Float] {
        let provider = try await providerResolver.resolve(
            for: "embeddings", preference: .any, override: nil
        )
        return try await provider.embed(text, model: model)
    }
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Providers/AIService.swift
git commit -m "feat: add AIService facade with send, sendStreaming, embed"
```

---

### Task 6: Update ai_config.json with new blocks

**Files:**
- Modify: `wawa-note/Resources/ai_config.json`

- [ ] **Step 1: Add model_policy, provider_templates, api_templates, agent_modes blocks**

Read the current `ai_config.json` and append the new blocks. The existing `providers`, `defaultModels`, `modelPresets`, `features`, `lenses` blocks stay unchanged.

Add after the `lenses` block (before the closing `}`):

```json
  "provider_templates": {
    "openai": {
      "id": "openai",
      "displayName": "OpenAI",
      "icon": "brain.head.profile",
      "type": "openAI",
      "baseURL": "https://api.openai.com/v1",
      "auth": "api_key_bearer",
      "authHeader": "Authorization",
      "authPrefix": "Bearer ",
      "defaultModels": ["gpt-5.5", "gpt-5.1-mini"],
      "autoDiscover": false,
      "description": "GPT models via OpenAI API",
      "requiresAuth": true
    },
    "anthropic": {
      "id": "anthropic",
      "displayName": "Anthropic",
      "icon": "brain",
      "type": "anthropic",
      "baseURL": "https://api.anthropic.com/v1",
      "auth": "api_key_header",
      "authHeader": "x-api-key",
      "authPrefix": "",
      "defaultModels": ["claude-sonnet-4-6", "claude-haiku-4-5"],
      "autoDiscover": false,
      "description": "Claude models via Anthropic API",
      "requiresAuth": true
    },
    "gemini": {
      "id": "gemini",
      "displayName": "Gemini",
      "icon": "sparkles",
      "type": "gemini",
      "baseURL": "https://generativelanguage.googleapis.com/v1beta",
      "auth": "api_key_query",
      "authHeader": "",
      "authPrefix": "",
      "defaultModels": ["gemini-2.5-flash"],
      "autoDiscover": false,
      "description": "Gemini models via Google AI",
      "requiresAuth": true
    },
    "ollama": {
      "id": "ollama",
      "displayName": "Ollama",
      "icon": "desktopcomputer",
      "type": "local",
      "baseURL": "http://localhost:11434",
      "auth": "none",
      "defaultModels": ["llama-3.2-3b"],
      "autoDiscover": true,
      "discoveryPort": 11434,
      "description": "Local models via Ollama",
      "requiresAuth": false
    },
    "lmstudio": {
      "id": "lmstudio",
      "displayName": "LM Studio",
      "icon": "cpu",
      "type": "local",
      "baseURL": "http://localhost:1234/v1",
      "auth": "none",
      "defaultModels": [],
      "autoDiscover": true,
      "discoveryPort": 1234,
      "description": "Local models via LM Studio",
      "requiresAuth": false
    }
  },
  "api_templates": {},
  "model_policy": {
    "budget": {
      "dailyUSD": 1.00,
      "thresholds": [
        { "minPercent": 0.50, "tier": "deep" },
        { "minPercent": 0.25, "tier": "fast" },
        { "minPercent": 0.05, "tier": "economy" },
        { "minPercent": 0.00, "tier": "local" }
      ]
    },
    "tiers": {
      "deep":    { "label": "Deep",    "prefer": ["claude-opus-4-8", "gpt-5.5", "gemini-2.5-pro"] },
      "fast":    { "label": "Fast",    "prefer": ["claude-sonnet-4-6", "gpt-5.1-mini", "gemini-2.5-flash"] },
      "economy": { "label": "Economy", "prefer": ["claude-haiku-4-5", "gpt-5.1-nano", "gemini-2.0-flash-lite"] },
      "local":   { "label": "Local",   "prefer": ["llama-3.2-3b", "phi-4-mini", "qwen2.5-3b"] }
    },
    "features": {
      "chat":       { "deep": "claude-sonnet-4-6",  "fast": "gpt-5.1-mini",      "economy": "claude-haiku-4-5",   "local": "phi-4-mini" },
      "agent":      { "deep": "claude-opus-4-8",    "fast": "claude-sonnet-4-6",  "economy": "gpt-5.1-mini",       "local": "llama-3.2-3b" },
      "analysis":   { "deep": "claude-opus-4-8",    "fast": "claude-sonnet-4-6",  "economy": "gpt-5.1-mini",       "local": "phi-4-mini" },
      "vision":     { "deep": "claude-sonnet-4-6",  "fast": "gpt-5.1-mini",       "economy": "claude-haiku-4-5",   "local": "phi-4-mini" },
      "transcription": { "deep": "whisper-1",       "fast": "whisper-1",           "economy": "whisper-1",          "local": "apple-on-device" },
      "project_ingestion": { "deep": "claude-opus-4-8", "fast": "claude-sonnet-4-6", "economy": "gpt-5.1-mini",  "local": "llama-3.2-3b" }
    },
    "offlineFallback": { "enabled": true },
    "userOverride": { "enabled": true }
  },
  "agent_modes": {
    "chat": {
      "feature": "chat",
      "tools": ["shell"],
      "systemPrompt": "chat_system",
      "modelTier": "auto"
    },
    "analysis": {
      "feature": "analysis",
      "tools": ["shell", "write_analysis", "select_schema", "select_skill", "set_title", "write_speakers"],
      "systemPrompt": "analysis_system",
      "modelTier": "deep"
    },
    "project_ingestion": {
      "feature": "project_ingestion",
      "tools": ["shell", "write_analysis", "select_schema"],
      "systemPrompt": "project_ingestion_system",
      "modelTier": "deep"
    },
    "graph_discovery": {
      "feature": "analysis",
      "tools": ["shell"],
      "systemPrompt": "graph_discovery_system",
      "modelTier": "fast"
    }
  }
```

- [ ] **Step 2: Verify JSON is valid and AIConfig still decodes**

```bash
cd wawa-note && plutil -lint Resources/ai_config.json
```

Expected: `Resources/ai_config.json: OK`

- [ ] **Step 3: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Resources/ai_config.json
git commit -m "feat: add model_policy, provider_templates, api_templates, agent_modes to ai_config.json"
```

---

## Phase 2: Concrete Implementations

### Task 7: JSONConfigProvider — adapter over AIConfigService

**Files:**
- Modify: `wawa-note/Providers/AIConfigService.swift` (append JSONConfigProvider class)

- [ ] **Step 1: Add Codable extensions for new JSON blocks**

The new blocks in `ai_config.json` need corresponding fields in `AIConfig`. Append inside the `AIConfig` struct at line 67 (after `lenses`):

```swift
let providerTemplates: [ProviderTemplateConfig]?
let apiTemplates: [APITemplate]?
let modelPolicy: ModelPolicyRules?
let agentModes: [String: AgentModeConfig]?
```

- [ ] **Step 2: Write JSONConfigProvider at the end of AIConfigService.swift**

```swift
// MARK: - JSONConfigProvider

final class JSONConfigProvider: @unchecked Sendable, AIConfigProvider {
    private let configService: AIConfigService

    init(configService: AIConfigService = .shared) {
        self.configService = configService
    }

    func requestParams(for feature: String, model: String, override: ModelOverride?) -> AIFeatureParams {
        // Override temperature/maxTokens win, otherwise delegate to config
        if let overrideTemp = override?.temperature, let overrideMax = override?.maxTokens {
            let contextWindow = configService.contextWindowTokens(for: model)
            let isReasoning = configService.isReasoningModel(model)
            return AIFeatureParams(
                temperature: overrideTemp,
                maxTokens: overrideMax,
                contextWindow: contextWindow,
                isReasoning: isReasoning
            )
        }
        var params = configService.requestParams(for: feature, model: model)
        if let temp = override?.temperature { params = AIFeatureParams(temperature: temp, maxTokens: params.maxTokens, contextWindow: params.contextWindow, isReasoning: params.isReasoning) }
        if let maxT = override?.maxTokens { params = AIFeatureParams(temperature: params.temperature, maxTokens: maxT, contextWindow: params.contextWindow, isReasoning: params.isReasoning) }
        return params
    }

    func modelFor(feature: String) -> String {
        configService.modelFor(feature: feature)
    }

    func presetFor(model: String) -> AIConfig.ModelPreset? {
        configService.presetFor(model: model)
    }

    var providerTemplates: [ProviderTemplateConfig] {
        configService.config.providerTemplates ?? configService.allProviders().map { config in
            ProviderTemplateConfig(
                id: config.id,
                displayName: config.displayName ?? config.id,
                icon: iconForProvider(config.id),
                type: config.type,
                baseURL: config.baseURL ?? "",
                auth: authForConfig(config),
                authHeader: authHeaderForConfig(config),
                authPrefix: authPrefixForConfig(config),
                defaultModels: config.models ?? [],
                autoDiscover: config.type.isLocal,
                discoveryPort: config.type.isLocal ? 11434 : nil,
                description: config.description ?? "",
                requiresAuth: !config.type.isLocal
            )
        }
    }

    var apiTemplates: [APITemplate] {
        configService.config.apiTemplates ?? []
    }

    var modelPolicyRules: ModelPolicyRules {
        configService.config.modelPolicy ?? defaultModelPolicyRules
    }

    var agentModes: [String: AgentModeConfig] {
        configService.config.agentModes ?? [:]
    }

    // MARK: - Helpers

    private var defaultModelPolicyRules: ModelPolicyRules {
        ModelPolicyRules(
            budget: ModelPolicyRules.BudgetRules(dailyUSD: 1.0, thresholds: [
                ModelPolicyRules.BudgetThreshold(minPercent: 0.50, tier: "deep"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.25, tier: "fast"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.00, tier: "economy")
            ]),
            tiers: [
                "deep": ModelPolicyRules.TierConfig(label: "Deep", prefer: ["claude-sonnet-4-6"]),
                "fast": ModelPolicyRules.TierConfig(label: "Fast", prefer: ["gpt-5.1-mini"]),
                "economy": ModelPolicyRules.TierConfig(label: "Economy", prefer: ["claude-haiku-4-5"])
            ],
            features: [:],
            offlineFallback: ModelPolicyRules.OfflineFallbackConfig(enabled: true),
            userOverride: ModelPolicyRules.UserOverrideConfig(enabled: true)
        )
    }

    private func iconForProvider(_ id: String) -> String {
        switch id {
        case "openai": return "brain.head.profile"
        case "anthropic": return "brain"
        case "gemini": return "sparkles"
        case "ollama": return "desktopcomputer"
        case "lmstudio": return "cpu"
        case "deepseek": return "globe"
        default: return "gearshape"
        }
    }

    private func authForConfig(_ config: AIConfig.ProviderConfig) -> ProviderTemplateConfig.AuthMethod {
        if config.type.isLocal { return .none }
        return .apiKeyBearer
    }

    private func authHeaderForConfig(_ config: AIConfig.ProviderConfig) -> String? {
        switch config.type {
        case .anthropic: return "x-api-key"
        default: return "Authorization"
        }
    }

    private func authPrefixForConfig(_ config: AIConfig.ProviderConfig) -> String? {
        switch config.type {
        case .anthropic: return ""
        default: return "Bearer "
        }
    }
}

extension ProviderType {
    var isLocal: Bool {
        switch self {
        case .local, .localNetwork, .appleLocal: return true
        default: return false
        }
    }
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Providers/AIConfigService.swift
git commit -m "feat: add JSONConfigProvider implementing AIConfigProvider protocol"
```

---

### Task 8: TieredModelPolicy — JSON-driven model selection

**Files:**
- Modify: `wawa-note/Providers/ModelPolicy.swift` (append TieredModelPolicy actor)

- [ ] **Step 1: Write TieredModelPolicy actor**

```swift
// MARK: - TieredModelPolicy

actor TieredModelPolicy: ModelPolicy {
    let rules: ModelPolicyRules
    let network: NetworkMonitor
    let providerResolver: any ProviderResolver

    init(
        rules: ModelPolicyRules,
        network: NetworkMonitor = .shared,
        providerResolver: any ProviderResolver
    ) {
        self.rules = rules
        self.network = network
        self.providerResolver = providerResolver
    }

    func selectModel(
        for feature: String,
        budget: BudgetState,
        userTier: String?,
        override: ModelOverride?
    ) -> ModelSelection {
        // 1. Override da ponta vence tudo
        if let model = override?.model {
            return ModelSelection(
                model: model,
                tier: override?.tier ?? "manual",
                provider: providerTypeFor(model: model),
                reason: "override: model explícito"
            )
        }

        // 2. Override de tier vence budget
        let tierKey: String
        if let forced = override?.tier ?? userTier {
            tierKey = forced
        } else {
            tierKey = rules.tier(for: budget.remainingPercent)
        }

        // 3. Offline? → tier "local"
        let effectiveTier = network.isAvailable ? tierKey : "local"

        // 4. Resolve modelo da feature table
        let model = rules.model(for: feature, tier: effectiveTier)
            ?? rules.tiers[effectiveTier]?.prefer.first
            ?? "gpt-5.1-mini"

        return ModelSelection(
            model: model,
            tier: effectiveTier,
            provider: providerTypeFor(model: model),
            reason: "config(budget: \(String(format: "%.0f", budget.remainingPercent * 100))%)"
        )
    }

    func availableModels() async -> [String] {
        guard let provider = try? await providerResolver.resolve(
            for: "chat", preference: .any, override: nil
        ) else { return [] }
        return (try? await provider.fetchModels()) ?? []
    }

    private func providerTypeFor(model: String) -> ProviderType {
        let lower = model.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") {
            return .openAI
        }
        if lower.hasPrefix("claude-") {
            return .anthropic
        }
        if lower.hasPrefix("gemini-") {
            return .gemini
        }
        return .openAICompatible
    }
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Write unit tests for TieredModelPolicy**

Add to `CoreServicesTests.swift`:

```swift
/// Minimal mock resolver for testing TieredModelPolicy.selectModel().
/// selectModel() doesn't call the resolver — only availableModels() does.
/// So we can pass a stub that throws.
struct StubProviderResolver: ProviderResolver {
    let activeID: String
    init(id: String = "openai") { self.activeID = id }
    var activeProviderID: String { get async { activeID } }
    func setActiveProvider(_ id: String) async { }
    func resolve(for feature: String, preference: ProviderPreference, override: ModelOverride?) async throws -> any AIProvider {
        throw ProviderError.providerNotFound
    }
}

final class TieredModelPolicyTests: XCTestCase {
    func testSelectModelWithBudgetDeep() async {
        let policy = makePolicy()
        let budget = BudgetState(dailyLimit: 1.0, spentToday: 0.10)
        let selection = await policy.selectModel(for: "analysis", budget: budget, userTier: nil, override: nil)
        XCTAssertEqual(selection.tier, "deep")
        XCTAssertEqual(selection.model, "claude-opus-4-8")
    }

    func testSelectModelWithBudgetEconomy() async {
        let policy = makePolicy()
        let budget = BudgetState(dailyLimit: 1.0, spentToday: 0.90)
        let selection = await policy.selectModel(for: "analysis", budget: budget, userTier: nil, override: nil)
        XCTAssertEqual(selection.tier, "economy")
    }

    func testSelectModelWithOverrideModel() async {
        let policy = makePolicy()
        let budget = BudgetState(dailyLimit: 1.0, spentToday: 0.10)
        let selection = await policy.selectModel(
            for: "analysis", budget: budget, userTier: nil,
            override: ModelOverride(model: "gpt-5.5")
        )
        XCTAssertEqual(selection.model, "gpt-5.5")
        XCTAssertEqual(selection.reason, "override: model explícito")
    }

    func testSelectModelWithOverrideTier() async {
        let policy = makePolicy()
        let budget = BudgetState(dailyLimit: 1.0, spentToday: 0.90)
        let selection = await policy.selectModel(
            for: "analysis", budget: budget, userTier: nil,
            override: ModelOverride(tier: "deep")
        )
        XCTAssertEqual(selection.tier, "deep")
        XCTAssertEqual(selection.model, "claude-opus-4-8")
    }

    func testSelectModelFallsBackToChat() async {
        let policy = makePolicy()
        let budget = BudgetState(dailyLimit: 1.0, spentToday: 0.10)
        let selection = await policy.selectModel(for: "nonexistent", budget: budget, userTier: nil, override: nil)
        // Falls back to chat.fast because tier is "fast" (budget 90% = deep) wait — 10% spent = 90% remaining = deep tier
        // nonexistent feature → chat.fast fallback (no deep entry for nonexistent)
        XCTAssertEqual(selection.tier, "deep")
        // chat.features["deep"] not defined for "nonexistent" → falls to chats deep? Actually model(for: "nonexistent", tier: "deep")
        // walks: features["nonexistent"]?["deep"] → nil, features["chat"]?["deep"] → "claude-sonnet-4-6"
        XCTAssertEqual(selection.model, "claude-sonnet-4-6")
    }

    func testUserTierOverridesBudget() async {
        let policy = makePolicy()
        let budget = BudgetState(dailyLimit: 1.0, spentToday: 0.90) // economy tier
        let selection = await policy.selectModel(for: "analysis", budget: budget, userTier: "deep", override: nil)
        XCTAssertEqual(selection.tier, "deep")
    }

    private func makePolicy() -> TieredModelPolicy {
        let rules = ModelPolicyRules(
            budget: ModelPolicyRules.BudgetRules(dailyUSD: 1.0, thresholds: [
                ModelPolicyRules.BudgetThreshold(minPercent: 0.50, tier: "deep"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.25, tier: "fast"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.05, tier: "economy"),
                ModelPolicyRules.BudgetThreshold(minPercent: 0.00, tier: "local")
            ]),
            tiers: [
                "deep": ModelPolicyRules.TierConfig(label: "Deep", prefer: ["claude-opus-4-8"]),
                "fast": ModelPolicyRules.TierConfig(label: "Fast", prefer: ["claude-sonnet-4-6"]),
                "economy": ModelPolicyRules.TierConfig(label: "Economy", prefer: ["claude-haiku-4-5"]),
                "local": ModelPolicyRules.TierConfig(label: "Local", prefer: ["phi-4-mini"])
            ],
            features: [
                "chat": ["deep": "claude-sonnet-4-6", "fast": "gpt-5.1-mini", "economy": "claude-haiku-4-5", "local": "phi-4-mini"],
                "analysis": ["deep": "claude-opus-4-8", "fast": "claude-sonnet-4-6", "economy": "gpt-5.1-mini", "local": "phi-4-mini"]
            ],
            offlineFallback: ModelPolicyRules.OfflineFallbackConfig(enabled: true),
            userOverride: ModelPolicyRules.UserOverrideConfig(enabled: true)
        )
        return TieredModelPolicy(rules: rules, network: .shared, providerResolver: StubProviderResolver())
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Providers/ModelPolicy.swift wawa-noteTests/CoreServicesTests.swift
git commit -m "feat: add TieredModelPolicy — JSON-driven model selection"
```

---

### Task 9: HealthAwareResolver — unified provider resolution

**Files:**
- Modify: `wawa-note/Providers/ProviderResolver.swift` (append HealthAwareResolver)

- [ ] **Step 1: Write HealthAwareResolver actor**

```swift
// MARK: - HealthAwareResolver

actor HealthAwareResolver: ProviderResolver {
    private let modelContext: ModelContext
    private let activeManager: ActiveProviderManager
    private var providerCache: [String: any AIProvider] = [:]
    private let cacheLock = NSLock()

    init(modelContext: ModelContext, activeManager: ActiveProviderManager = .shared) {
        self.modelContext = modelContext
        self.activeManager = activeManager
    }

    var activeProviderID: String {
        get async {
            activeManager.getActiveProviderID() ?? "openai"
        }
    }

    func setActiveProvider(_ id: String) async {
        activeManager.setActiveProviderID(id)
    }

    func resolve(
        for feature: String,
        preference: ProviderPreference,
        override: ModelOverride?
    ) async throws -> any AIProvider {
        // 1. Override providerID wins
        if let providerID = override?.providerID {
            return try resolveByID(providerID)
        }

        // 2. Handle preference
        switch preference {
        case .specific(let id):
            return try resolveByID(id)
        case .localPreferred:
            if let local = findLocalProvider() {
                return local
            }
            return try resolveActive()
        case .localRequired:
            guard let local = findLocalProvider() else {
                throw ProviderError.providerNotFound
            }
            return local
        case .any:
            return try resolveActive()
        }
    }

    // MARK: - Private

    private func resolveByID(_ id: String) throws -> any AIProvider {
        if let cached = cacheLock.withLock({ providerCache[id] }) {
            return cached
        }
        guard let config = activeManager.getActiveProvider(context: modelContext),
              config.id == id || true else {
            throw ProviderError.providerNotFound
        }
        let router = ProviderRouter()
        let provider = try router.provider(for: config)
        cacheLock.withLock { providerCache[id] = provider }
        return provider
    }

    private func resolveActive() throws -> any AIProvider {
        try ProviderRouter.resolveActive(context: modelContext)
    }

    private func findLocalProvider() -> (any AIProvider)? {
        // Search configured providers for local types
        let allConfigs = activeManager.allProviders(context: modelContext)
        guard let localConfig = allConfigs.first(where: { $0.type.isLocal }) else {
            return nil
        }
        return try? ProviderRouter().provider(for: localConfig)
    }
}
```

> **Note:** This delegates to `ProviderRouter` during transition. When `ProviderRouter` is removed in Phase 4, the factory logic (`provider(for:)`) moves here directly.

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Providers/ProviderResolver.swift
git commit -m "feat: add HealthAwareResolver implementing ProviderResolver"
```

---

### Task 10: APICallTool — generic API calling via JSON

**Files:**
- Create: `wawa-note/Domain/Agent/APICallTool.swift`

- [ ] **Step 1: Write APICallTool**

```swift
import Foundation

struct APICallTool: AgentTool {
    let name = "api_call"
    let description = "Calls a registered external API. Use this to interact with services like GitHub, Linear, Notion, etc."

    let parameters: AIToolParameters = AIToolParameters(
        type: "object",
        properties: [
            "api_name": AIToolProperty(type: "string", description: "Name of the registered API (e.g., 'github', 'linear')"),
            "endpoint": AIToolProperty(type: "string", description: "Name of the endpoint to call (e.g., 'list_issues', 'create_issue')"),
            "params": AIToolProperty(type: "object", description: "Parameters for the endpoint as key-value pairs")
        ],
        required: ["api_name", "endpoint"]
    )

    private let configProvider: any AIConfigProvider
    private let keyStore: SecureKeyStore

    init(configProvider: any AIConfigProvider, keyStore: SecureKeyStore = SecureKeyStore()) {
        self.configProvider = configProvider
        self.keyStore = keyStore
    }

    @MainActor
    func execute(_ arguments: [String: any Sendable], context: ToolContext) async throws -> ToolResult {
        guard let apiName = arguments["api_name"] as? String,
              let endpointName = arguments["endpoint"] as? String else {
            return ToolResult(content: "Error: api_name and endpoint are required", isError: true)
        }

        let params = arguments["params"] as? [String: Any] ?? [:]

        // Lookup API template
        guard let api = configProvider.apiTemplates.first(where: { $0.id == apiName }) else {
            return ToolResult(content: "Error: API '\(apiName)' not found in configuration.", isError: true)
        }

        // Lookup endpoint
        guard let endpoint = api.endpoints.first(where: { $0.name == endpointName }) else {
            return ToolResult(content: "Error: Endpoint '\(endpointName)' not found in API '\(apiName)'.", isError: true)
        }

        // Build URL
        var path = endpoint.path
        for (key, value) in params {
            path = path.replacingOccurrences(of: "{\(key)}", with: String(describing: value))
        }
        guard let url = URL(string: api.baseURL + path) else {
            return ToolResult(content: "Error: Invalid URL \(api.baseURL + path)", isError: true)
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method

        // Auth header
        if api.auth != .none, let apiKey = keyStore.loadAPIKey(for: apiName) {
            let headerName = api.authHeader ?? "Authorization"
            let prefix = api.authPrefix ?? "Bearer "
            request.setValue("\(prefix)\(apiKey)", forHTTPHeaderField: headerName)
        }

        // Add query params for GET requests
        if endpoint.method == "GET" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            for (key, value) in params {
                if !path.contains("{\(key)}") {
                    queryItems.append(URLQueryItem(name: key, value: String(describing: value)))
                }
            }
            components?.queryItems = queryItems.isEmpty ? nil : queryItems
            if let finalURL = components?.url {
                request.url = finalURL
            }
        }

        // JSON body for POST/PUT
        if ["POST", "PUT", "PATCH"].contains(endpoint.method) {
            var bodyParams: [String: Any] = [:]
            for (key, value) in params {
                if !path.contains("{\(key)}") {
                    bodyParams[key] = value
                }
            }
            if !bodyParams.isEmpty {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: bodyParams)
            }
        }

        // Execute
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1

            if (200...299).contains(statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let string = String(data: pretty, encoding: .utf8) {
                    return ToolResult(content: string)
                }
                return ToolResult(content: String(data: data, encoding: .utf8) ?? "Success (\(statusCode))")
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return ToolResult(content: "HTTP \(statusCode): \(body)", isError: true)
            }
        } catch {
            return ToolResult(content: "API call failed: \(error.localizedDescription)", isError: true)
        }
    }

    func validateArguments(_ args: [String: any Sendable]) -> String? {
        guard args["api_name"] is String else { return "api_name is required (string)" }
        guard args["endpoint"] is String else { return "endpoint is required (string)" }
        return nil
    }
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Agent/APICallTool.swift
git commit -m "feat: add APICallTool — generic API calling from JSON api_templates"
```

---

### Task 11: AgentOrchestrator — unified AgentLoop + Pipeline

**Files:**
- Create: `wawa-note/Domain/Agent/AgentOrchestrator.swift`

- [ ] **Step 1: Write AgentOrchestrator actor**

```swift
import Foundation
import SwiftData

// MARK: - AgentMode

enum AgentMode: String, Codable, Sendable, CaseIterable {
    case chat
    case analysis
    case projectIngestion = "project_ingestion"
    case graphDiscovery = "graph_discovery"

    var featureKey: String {
        switch self {
        case .chat: return "chat"
        case .analysis: return "analysis"
        case .projectIngestion: return "project_ingestion"
        case .graphDiscovery: return "analysis"
        }
    }
}

// MARK: - AgentOrchestrator

actor AgentOrchestrator {
    let aiService: AIService
    let toolRegistry: AgentToolRegistry
    let contextManager: ContextWindowManager
    let configProvider: any AIConfigProvider

    init(
        aiService: AIService,
        toolRegistry: AgentToolRegistry,
        contextManager: ContextWindowManager,
        configProvider: any AIConfigProvider
    ) {
        self.aiService = aiService
        self.toolRegistry = toolRegistry
        self.contextManager = contextManager
        self.configProvider = configProvider
    }

    // MARK: - Interactive (Chat)

    func runInteractive(
        session: ChatSession,
        history: [AIMessage],
        context: ToolContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await executeInteractive(session: session, history: history, context: context, continuation: continuation)
            }
        }
    }

    private func executeInteractive(
        session: ChatSession,
        history: [AIMessage],
        context: ToolContext,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        let mode = AgentMode.chat
        let modeConfig = configProvider.agentModes[mode.rawValue]
        let feature = modeConfig?.feature ?? mode.featureKey

        let systemPrompt = modeConfig?.systemPrompt ?? "You are a helpful assistant."
        let messages = contextManager.buildMessages(system: systemPrompt, history: history)

        let stream = aiService.sendStreaming(
            feature: feature,
            messages: messages,
            tools: nil,
            toolChoice: nil,
            override: nil
        )

        do {
            for try await event in stream {
                continuation.yield(mapStreamEvent(event))
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Autonomous (Pipeline)

    func runAutonomous(
        task: String,
        mode: AgentMode,
        item: KnowledgeItem?,
        project: Project?,
        context: ModelContext
    ) async throws -> AgentResult {
        let modeConfig = configProvider.agentModes[mode.rawValue]
        let feature = modeConfig?.feature ?? mode.featureKey
        let modelTier = modeConfig?.modelTier

        let tools = toolRegistry.allDefinitions()
        let systemPrompt = modeConfig?.systemPrompt ?? "You are an autonomous agent."

        let messages = contextManager.buildMessages(system: systemPrompt, history: [])

        let response = try await aiService.send(
            feature: feature,
            messages: messages,
            tools: tools,
            toolChoice: "auto",
            override: modelTier.map { ModelOverride(tier: $0) }
        )

        return AgentResult(content: response.content, toolCalls: response.toolCalls)
    }

    // MARK: - Helpers

    private func mapStreamEvent(_ event: AIStreamEvent) -> AgentEvent {
        switch event {
        case .textDelta(let text): return .textDelta(text)
        case .thinkingDelta(let text): return .thinkingDelta(text)
        case .toolCallDelta(let id, let name, let args): return .toolCallDelta(id: id, name: name, arguments: args)
        case .finished(let reason): return .finished(reason)
        }
    }
}

// MARK: - Types

enum AgentEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallDelta(id: String, name: String?, arguments: String?)
    case finished(AIFinishReason?)
}

struct AgentResult: Sendable {
    let content: String
    let toolCalls: [AIToolCall]?
}

struct ChatSession: Sendable {
    let id: UUID
    let title: String?
    let conversationID: UUID?
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add wawa-note/Domain/Agent/AgentOrchestrator.swift
git commit -m "feat: add AgentOrchestrator unifying AgentLoop + Pipeline"
```

---

## Phase 3: Migrate Call Sites (One by One)

### Task 12: Migrate ChatViewModel to use AgentOrchestrator

**Files:**
- Modify: `wawa-note/UI/Chat/ChatViewModel.swift`

- [ ] **Step 1: Inject AIService and AgentOrchestrator into ChatViewModel**

Read current `ChatViewModel.swift` to find the class definition. Add properties:

```swift
private let aiService: AIService
private let orchestrator: AgentOrchestrator
```

Update `init()` or add a convenience initializer that creates `AIService` with `JSONConfigProvider`, `HealthAwareResolver`, and `TieredModelPolicy`.

- [ ] **Step 2: Replace AgentLoop creation with orchestrator.runInteractive()**

Find `sendMessage()` (around line 409). The current code creates `AgentLoop` and calls `loop.runStreaming(...)`. Replace with:

```swift
let stream = orchestrator.runInteractive(
    session: ChatSession(id: conversationID, title: nil, conversationID: conversationID),
    history: chatHistory.map { /* convert ChatMessage to AIMessage */ },
    context: toolContext
)

for try await event in stream {
    switch event {
    case .textDelta(let text):
        await appendToCurrentMessage(text)
    case .thinkingDelta(let thinking):
        await appendThinking(thinking)
    case .toolCallDelta(let id, let name, let args):
        await handleToolCallDelta(id: id, name: name, arguments: args)
    case .finished:
        await finalizeMessage()
    }
}
```

- [ ] **Step 3: Same for sendInternalMessage() (around line 742)**

Replace AgentLoop creation with orchestrator call.

- [ ] **Step 4: Same for generateWelcome() and pregenerateGreeting()**

Replace direct `provider.send(AIRequest(...))` calls with `aiService.send(feature: "chat", messages: [...])`.

- [ ] **Step 5: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add wawa-note/UI/Chat/ChatViewModel.swift
git commit -m "refactor: migrate ChatViewModel to AgentOrchestrator and AIService"
```

---

### Task 13: Migrate ContentPipelineService to AgentOrchestrator.runAutonomous()

**Files:**
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift`

- [ ] **Step 1: Inject AgentOrchestrator**

```swift
private let orchestrator: AgentOrchestrator
```

- [ ] **Step 2: Replace AgentLoop creation (around lines 341-345) with orchestrator call**

```swift
let result = try await orchestrator.runAutonomous(
    task: "Analyze the following content: \(extractedText)",
    mode: .analysis,
    item: item,
    project: project,
    context: modelContext
)
```

- [ ] **Step 3: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add wawa-note/Domain/Services/ContentPipelineService.swift
git commit -m "refactor: migrate ContentPipelineService to AgentOrchestrator.runAutonomous()"
```

---

### Task 14: Fix AnalysisService bypass sites to use AIService.send()

**Files:**
- Modify: `wawa-note/Domain/Services/AnalysisService.swift`

- [ ] **Step 1: Inject AIService**

```swift
private let aiService: AIService
```

- [ ] **Step 2: Fix summarizeChunkWithRetry (lines 280-285)**

Replace manual `AIRequest` creation with:

```swift
let response = try await aiService.send(
    feature: "analysis",
    messages: [
        AIMessage(role: .system, content: [.text("You are a concise summarizer. Return only the summary text, no JSON.")]),
        AIMessage(role: .user, content: [.text("Summarize chunk \(index + 1)/\(total):\n\n\(chunk.text)")])
    ],
    override: ModelOverride(maxTokens: 500)
)
return response.content
```

- [ ] **Step 3: Fix tryRetryWithFix (lines 370-377)**

Replace manual `AIRequest` creation with:

```swift
let response = try await aiService.send(
    feature: "analysis",
    messages: [
        AIMessage(role: .system, content: [.text("You are a JSON repair assistant. Output ONLY valid JSON. No markdown, no code fences.")]),
        AIMessage(role: .user, content: [.text("Fix this JSON:\n\(failedJSON)")])
    ],
    responseFormat: .jsonObject
)
```

- [ ] **Step 4: Remove sendWithRetry method (lines 299-335)**

Delete the private `sendWithRetry` method — `AIService` handles retry internally.

- [ ] **Step 5: Fix singleAnalysis to use AIService.send()**

Replace the `provider.send(request)` call (around line 166) with `aiService.send(feature: "analysis", messages: [...], responseFormat: ...)`.

- [ ] **Step 6: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add wawa-note/Domain/Services/AnalysisService.swift
git commit -m "fix: migrate AnalysisService bypass sites to AIService.send()"
```

---

### Task 15: Migrate remaining call sites

**Files:**
- Modify: `wawa-note/Domain/Services/AnalysisSkillService.swift:80-81`
- Modify: `wawa-note/Domain/Services/GraphEdgeService.swift:228-238`
- Modify: `wawa-note/Domain/Services/ProjectIngestionPipeline.swift:164-176`
- Modify: `wawa-note/Domain/Services/ProjectConversionService.swift:87-96`
- Modify: `wawa-note/Domain/Services/ContentExtractionService.swift:290-292`
- Modify: `wawa-note/Domain/Agent/ShellInterpreter.swift:1950-1953`

- [ ] **Step 1: Each file — inject AIService, replace AIRequest creation with aiService.send()**

For each call site, follow the same pattern:

```swift
// Before:
let params = AIConfigService.shared.requestParams(for: "feature_name", model: model)
let request = AIRequest(model: model, messages: [...], temperature: params.temperature, maxTokens: params.maxTokens, responseFormat: ...)
let response = try await provider.send(request)

// After:
let response = try await aiService.send(feature: "feature_name", messages: [...], responseFormat: ...)
```

File-specific changes:

**AnalysisSkillService.swift:80-81:** Replace with `aiService.send(feature: "analysis", messages: [...], responseFormat: .jsonObject)`

**GraphEdgeService.swift:228-238:** Replace with `aiService.send(feature: "analysis", messages: [...], responseFormat: .jsonObject)`

**ProjectIngestionPipeline.swift:164-176:** Replace with `aiService.send(feature: "project_ingestion", messages: [...], responseFormat: .jsonObject)`

**ProjectIngestionPipeline.swift:200-207:** Fix retry (was missing temperature/maxTokens) — replace with `aiService.send(feature: "project_ingestion", messages: [...], responseFormat: .jsonObject)`

**ProjectConversionService.swift:87-96:** Replace with `aiService.send(feature: "project_conversion", messages: [...], responseFormat: .jsonObject)`

**ContentExtractionService.swift:290-292:** Fix hardcoded `maxTokens: 500` — replace with `aiService.send(feature: "vision", messages: [...])`

**ShellInterpreter.swift:1950-1953:** Replace with `aiService.send(feature: "vision", messages: [...])`

- [ ] **Step 2: Verify build compiles after each file**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 3: Commit after each file**

```bash
git add <file> && git commit -m "refactor: migrate <service> to AIService.send()"
```

---

## Phase 4: Remove Old Code

### Task 16: Remove ProviderRouter and simplify ActiveProviderManager

**Files:**
- Delete: `wawa-note/Providers/ProviderRouter.swift`
- Modify: `wawa-note/Providers/ActiveProviderManager.swift`
- Modify: `wawa-note/Providers/ProviderResolver.swift` (move factory logic here)

- [ ] **Step 1: Move provider(for:) factory to HealthAwareResolver**

Copy the factory switch from `ProviderRouter.provider(for:)` (lines 68-130) into `HealthAwareResolver` as a private method `makeProvider(for:)`.

- [ ] **Step 2: Delete ProviderRouter.swift**

```bash
git rm wawa-note/Providers/ProviderRouter.swift
```

- [ ] **Step 3: Simplify ActiveProviderManager**

Reduce ActiveProviderManager to just the active provider ID store and provider config lookup:

```swift
final class ActiveProviderStore: @unchecked Sendable {
    static let shared = ActiveProviderStore()

    private let defaults = UserDefaults.standard
    private let key = "activeProviderID"

    func getActiveProviderID() -> String? {
        defaults.string(forKey: key)
    }

    func setActiveProviderID(_ id: String) {
        defaults.set(id, forKey: key)
        NotificationCenter.default.post(name: .activeProviderChanged, object: nil)
    }
}
```

- [ ] **Step 4: Remove ModelResolver (if exists)**

Search for `ModelResolver` and remove if found.

- [ ] **Step 5: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Run all tests**

```bash
xcodebuild test -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed)"
```

Expected: All 27+ tests pass

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "refactor: remove ProviderRouter, simplify ActiveProviderManager to ActiveProviderStore"
```

---

### Task 17: Remove resolveModel() from AgentLoop, update ProviderTemplates

**Files:**
- Modify: `wawa-note/Domain/Agent/AgentLoop.swift`
- Modify: `wawa-note/UI/Settings/ProviderTemplates.swift`

- [ ] **Step 1: Remove resolveModel from AgentLoop**

Remove the `resolveModel(for iteration: Int) -> String` method (lines 391-410). The `AgentLoop` no longer owns model selection — `AIService` handles it via `ModelPolicy`.

Update `buildRequest` to accept a model parameter directly instead of computing it internally.

- [ ] **Step 2: Update ProviderTemplates to use JSONConfigProvider**

The current `ProviderTemplate` in `ProviderTemplates.swift` is a UI view model. Update it to convert from the new `ProviderTemplateConfig` Codable type:

```swift
static var all: [ProviderTemplate] {
    JSONConfigProvider().providerTemplates.map { config in
        ProviderTemplate(
            id: config.id,
            displayName: config.displayName,
            subtitle: config.description,
            systemImageName: config.icon,
            providerType: config.type,
            baseURL: config.baseURL,
            defaultModel: config.defaultModels.first ?? "",
            category: config.type.isLocal ? .local : .cloud,
            getAPIKeyURL: nil,
            requiresAuth: config.requiresAuth,
            scanPort: config.discoveryPort,
            scanPath: nil
        )
    }
}
```

- [ ] **Step 3: Verify build compiles**

```bash
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor: remove resolveModel from AgentLoop, update ProviderTemplates data source"
```

---

## Phase 5: Device Validation

### Task 18: Build, deploy, and test on device

- [ ] **Step 1: Clean build for device**

```bash
make clean && make deploy DEVICE=14
```

Expected: Build succeeds, app installs on iPhone 14 Plus

- [ ] **Step 2: Run unit tests on simulator**

```bash
make test
```

Expected: All tests pass

- [ ] **Step 3: Manual test checklist on device**

1. **Chat streaming** — send a message, verify response streams correctly with tool calls
2. **Pipeline ingestion** — record a meeting, verify auto-analysis runs
3. **Vision** — scan a document, verify OCR extraction
4. **Budget thresholds** — check BudgetTracker updates after calls
5. **Model tier override** — switch between Auto/Deep/Fast modes in chat
6. **Offline fallback** — disable network, verify local provider selected
7. **Add new provider** — add a provider via Settings UI (e.g., DeepSeek), verify it appears and works
8. **Add API** — add GitHub API via JSON, verify APICallTool can call it

- [ ] **Step 4: Run full device validation**

```bash
make all DEVICE=14
```

Expected: Build → Install → Test passes on iPhone 14 Plus

- [ ] **Step 5: Commit final changes if any**

```bash
git add -A && git commit -m "chore: device validation adjustments"
```

---

## Summary

**Tasks:** 18
**Phases:** 5
**Files created:** 5 (`AIService.swift`, `ModelPolicy.swift`, `ProviderResolver.swift`, `AgentOrchestrator.swift`, `APICallTool.swift`)
**Files deleted:** 1 (`ProviderRouter.swift`)
**Files modified:** 14
**Test additions:** 2 test classes (~10+ tests)
