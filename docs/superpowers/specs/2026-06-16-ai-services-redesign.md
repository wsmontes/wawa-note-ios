# AI Services Redesign — Spec

Date: 2026-06-16
Status: Design approved
Principle: Máxima flexibilidade — adicionar providers, modelos, features sem mexer no core

## Motivation

A arquitetura atual de AI Services tem 4 problemas estruturais:

1. **Bypass do AIConfigService** — 4 dos 15 call sites criam `AIRequest` sem usar `requestParams(for:model:)`, deixando `temperature`/`maxTokens` soltos ou hardcoded
2. **AgentLoop + Pipeline duplicados** — `ChatViewModel` e `ContentPipelineService` cada um inicializa seu próprio `AgentLoop` com tools, model resolution e system prompts diferentes
3. **Provider resolution com muita indireção** — `ProviderRouter` → `ActiveProviderManager` → `ProviderHealthMonitor` → `ProviderPool` para uma decisão que deveria ser simples
4. **Model selection espalhada** — `AgentLoop.resolveModel()`, `BudgetTracker.recommendedTier`, `ActiveProviderManager.bestProviderFor()`, `ModelResolver` — 4 lugares decidindo qual modelo usar

Além disso, olhando para frente (6-12 meses), precisamos que:
- Adicionar um provider novo (DeepSeek, Mistral, xAI) seja **zero código** — só JSON
- Adicionar uma API externa (GitHub, Linear, Notion) como tool pro agente seja **zero código** — só JSON + skill prompt
- A UI de providers e APIs seja **100% data-driven** a partir do `ai_config.json`

## Constraints

- `ai_config.json` mantido como fonte da verdade (extend only)
- Provider API implementations (`AnthropicProvider`, `GeminiProvider`, `OpenAICompatibleProvider`) mantidas — podem ser refatoradas internamente mas APIs externas continuam funcionando
- SwiftData models podem mudar
- Settings UI pode mudar
- ProviderRouter, ActiveProviderManager, AIConfigService podem ser substituídos

---

## Design

### 1. AIService — Fachada Única

**Princípio:** Um ponto de entrada. Zero bypass por construção.

```swift
actor AIService {
    let configProvider: AIConfigProvider
    let providerResolver: ProviderResolver
    let modelPolicy: ModelPolicy
    let retryConfig: RetryPolicy

    func send(feature: String, messages: [AIMessage],
              tools: [AIToolDefinition]? = nil,
              responseFormat: ResponseFormat? = nil) async throws -> AIResponse

    func sendStreaming(feature: String, messages: [AIMessage], ...) -> AsyncThrowingStream<AIStreamEvent, Error>

    func embed(text: String, model: String) async throws -> [Float]
}
```

**AIFeatureRequest** substitui `AIRequest` — `temperature` e `maxTokens` não são expostos ao caller. Vêm sempre do `AIConfigProvider`.

| Campo | AIRequest (atual) | AIFeatureRequest (novo) |
|---|---|---|
| `temperature` | Optional — caller decide | Não existe — vem do config |
| `maxTokens` | Optional — caller decide | Não existe — vem do config |
| `model` | String obrigatória | String opcional (override) |
| `feature` | Não existe | String — ex: "chat", "analysis" |

Fluxo interno do `send()`:
1. `modelPolicy.selectModel(for: feature, budget:)` → escolhe modelo
2. `configProvider.requestParams(for: feature, model:)` → temperature, maxTokens
3. `providerResolver.resolve(for: feature, preference:)` → `any AIProvider`
4. Constrói `AIRequest` interno (caller nunca vê)
5. `provider.send(request)` com retry + circuit breaker

### 2. Protocolos Internos

Três protocolos injetáveis no `AIService`, cada um com implementação padrão trocável:

```swift
protocol AIConfigProvider: Sendable {
    func requestParams(for feature: String, model: String) -> AIFeatureParams
    func modelFor(feature: String) -> String
    func presetFor(model: String) -> ModelPreset?
    var providerTemplates: [ProviderTemplate] { get }
    var apiTemplates: [APITemplate] { get }
    var modelPolicyRules: ModelPolicyRules { get }
}

protocol ProviderResolver: Sendable {
    func resolve(for feature: String, preference: ProviderPreference) async throws -> any AIProvider
    var activeProviderID: String { get async }
    func setActiveProvider(_ id: String) async
}

protocol ModelPolicy: Sendable {
    func selectModel(for feature: String, budget: BudgetState, userTier: String?) -> ModelSelection
    func availableModels() async -> [String]
}
```

Implementações padrão:
- `JSONConfigProvider` — lê `ai_config.json`, implementa `AIConfigProvider`
- `HealthAwareResolver` — absorve ProviderRouter + ActiveProviderManager + HealthMonitor + Pool
- `TieredModelPolicy` — motor de rules que avalia thresholds, tiers, e feature mapping do JSON

### 3. AgentOrchestrator — Unificado

Substitui `AgentLoop` + `ContentPipelineService`. Um orquestrador, modos diferentes:

```swift
actor AgentOrchestrator {
    let aiService: AIService
    let toolRegistry: AgentToolRegistry
    let contextManager: ContextWindowManager

    func runInteractive(session: ChatSession, history: [AIMessage],
                        context: ToolContext) -> AsyncThrowingStream<AgentEvent, Error>

    func runAutonomous(task: AgentTask, item: KnowledgeItem,
                       project: Project?) async throws -> AgentResult
}

enum AgentMode: String, Codable {
    case chat
    case analysis
    case projectIngestion
    case graphDiscovery
}
```

**Configurável via `ai_config.json` → `agent_modes`:**
```json
{
  "agent_modes": {
    "chat": {
      "feature": "chat",
      "tools": ["shell", "api_call"],
      "system_prompt": "chat_system",
      "model_tier": "auto"
    },
    "analysis": {
      "feature": "analysis",
      "tools": ["shell", "write_analysis", "select_schema", "select_skill", "set_title", "write_speakers", "api_call"],
      "system_prompt": "analysis_system",
      "model_tier": "deep"
    }
  }
}
```

### 4. ModelPolicy — 100% JSON-Driven

Nenhuma regra de seleção de modelo no Swift. O `TieredModelPolicy` é um motor que avalia regras declaradas no JSON:

```json
{
  "model_policy": {
    "budget": {
      "daily_usd": 1.00,
      "thresholds": [
        { "min_percent": 0.50, "tier": "deep" },
        { "min_percent": 0.25, "tier": "fast" },
        { "min_percent": 0.05, "tier": "economy" },
        { "min_percent": 0.00, "tier": "local" }
      ]
    },
    "tiers": {
      "deep":    { "prefer": ["claude-opus-4-8", "gpt-5.5", "gemini-2.5-pro"] },
      "fast":    { "prefer": ["claude-sonnet-4-6", "gpt-5.1-mini", "gemini-2.5-flash"] },
      "economy": { "prefer": ["claude-haiku-4-5", "gpt-5.1-nano", "gemini-2.0-flash-lite"] },
      "local":   { "prefer": ["llama-3.2-3b", "phi-4-mini", "qwen2.5-3b"] }
    },
    "features": {
      "chat":       { "deep": "claude-sonnet-4-6",  "fast": "gpt-5.1-mini", "economy": "claude-haiku-4-5", "local": "phi-4-mini" },
      "agent":      { "deep": "claude-opus-4-8",    "fast": "claude-sonnet-4-6", "economy": "gpt-5.1-mini", "local": "llama-3.2-3b" },
      "analysis":   { "deep": "claude-opus-4-8",    "fast": "claude-sonnet-4-6", "economy": "gpt-5.1-mini", "local": "phi-4-mini" },
      "vision":     { "deep": "claude-sonnet-4-6",  "fast": "gpt-5.1-mini", "economy": "claude-haiku-4-5", "local": "phi-4-mini" },
      "transcription": { "deep": "whisper-1", "fast": "whisper-1", "economy": "whisper-1", "local": "apple-on-device" },
      "project_ingestion": { "deep": "claude-opus-4-8", "fast": "claude-sonnet-4-6", "economy": "gpt-5.1-mini", "local": "llama-3.2-3b" }
    },
    "offline_fallback": { "enabled": true },
    "user_override": { "enabled": true }
  }
}
```

O Swift só faz lookups: `thresholds[budget%]` → tier → `features[feature][tier]` → model string → provider prefix.

### 5. Provider Templates — Data-Driven UI

Templates de providers são definidos no JSON. A UI renderiza dinamicamente. Zero Swift pra adicionar provider OpenAI-compatível.

```json
{
  "provider_templates": {
    "openai": {
      "display_name": "OpenAI",
      "icon": "openai",
      "type": "openAI",
      "base_url": "https://api.openai.com/v1",
      "auth": "api_key_bearer",
      "auth_header": "Authorization",
      "auth_prefix": "Bearer ",
      "default_models": ["gpt-5.5", "gpt-5.1-mini"],
      "description": "GPT models via OpenAI API"
    },
    "deepseek": {
      "display_name": "DeepSeek",
      "icon": "deepseek",
      "type": "openAICompatible",
      "base_url": "https://api.deepseek.com/v1",
      "auth": "api_key_bearer",
      "auth_header": "Authorization",
      "auth_prefix": "Bearer ",
      "default_models": ["deepseek-chat", "deepseek-reasoner"],
      "description": "DeepSeek V3 and R1 models"
    }
  }
}
```

```swift
struct ProviderTemplate: Codable, Identifiable, Sendable {
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
}
```

UI renderiza `ForEach(configProvider.providerTemplates)` — grid dinâmico.

**Adicionar DeepSeek:** 1 entrada no JSON → botão aparece → usuário cola API key → salva → provider vivo. 30 segundos.

**Adicionar provider com API proprietária (ex: Cohere):** 1 entrada JSON (botão aparece) + 1 arquivo `CohereProvider.swift` + 1 case no `ProviderResolver`.

### 6. API Templates — APIs viram Tools

Mesmo padrão dos provider_templates, generalizado para qualquer API REST ou GraphQL.

```json
{
  "api_templates": {
    "github": {
      "display_name": "GitHub",
      "icon": "github",
      "base_url": "https://api.github.com",
      "auth": "api_key_bearer",
      "auth_header": "Authorization",
      "auth_prefix": "Bearer ",
      "endpoints": [
        {
          "name": "list_issues",
          "method": "GET",
          "path": "/repos/{owner}/{repo}/issues",
          "description": "Lista issues de um repositório",
          "parameters": {
            "owner": { "type": "string", "required": true },
            "repo": { "type": "string", "required": true },
            "state": { "type": "string", "enum": ["open", "closed", "all"], "default": "open" }
          }
        }
      ],
      "skill": {
        "name": "GitHub API",
        "prompt": "You have access to the GitHub API. Use it to manage issues and pull requests...",
        "when_to_use": "When the user asks about GitHub issues, PRs, or repository files."
      }
    }
  }
}
```

**`APICallTool`** — uma AgentTool genérica:

```swift
struct APICallTool: AgentTool {
    let name = "api_call"
    let description = "Chama uma API externa registrada."
    let parameters: AIToolParameters = [
        "api_name": { type: "string" },
        "endpoint":  { type: "string" },
        "params":    { type: "object" }
    ]

    func execute(_ input: ToolInput, context: ToolContext) async throws -> ToolResult {
        // 1. Lookup api_templates[input.api_name]
        // 2. Lookup endpoint
        // 3. Build URL (substituir {placeholders})
        // 4. Build request (method, headers, auth, body)
        // 5. Execute HTTP request
        // 6. Return formatted response
    }
}
```

Skills são injetadas no system prompt do agente pelo `AgentOrchestrator`, ensinando o modelo quando e como usar cada API.

### 7. Estrutura Final do `ai_config.json`

```json
{
  "provider_templates": { ... },
  "api_templates": { ... },
  "model_policy": { ... },
  "features": { ... },
  "agent_modes": { ... },
  "providers": { ... },
  "apis": { ... }
}
```

### 8. O Que Some / O Que Fica

| Arquivo | Ação |
|---|---|
| `ProviderRouter.swift` | 🗑️ Remove — absorvido por HealthAwareResolver |
| `ActiveProviderManager.swift` | ✂️ Simplifica para ~20 linhas (ActiveProviderStore) |
| `ProviderTemplates.swift` | 🗑️ Remove — substituído por ProviderTemplate Codable |
| `ModelResolver` (classe não usada) | 🗑️ Remove |
| `AIConfigService.swift` | ✂️ Refatora para JSONConfigProvider |
| `AgentLoop.swift` | ✂️ Refatora para AgentOrchestrator |
| `ContentPipelineService.swift` | ✂️ Absorvido por AgentOrchestrator.runAutonomous() |
| `ProviderAdapter.swift` | ✅ Mantém (response normalization) |
| `AnthropicProvider.swift` | ✅ Mantém |
| `GeminiProvider.swift` | ✅ Mantém |
| `OpenAICompatibleProvider.swift` | ✅ Mantém |
| `AIProvider.swift` | ✅ Mantém (protocol + tipos base) |

**Novos arquivos:**
| Arquivo | Conteúdo |
|---|---|
| `AIService.swift` | Fachada única — send(), sendStreaming(), embed() |
| `AgentOrchestrator.swift` | Unifica AgentLoop + Pipeline |
| `ModelPolicy.swift` | Protocol + TieredModelPolicy + ModelPolicyRules (Codable) |
| `ProviderResolver.swift` | Protocol + HealthAwareResolver |
| `APICallTool.swift` | Tool genérica para chamar APIs definidas no JSON |

### 9. Plano de Migração (5 fases)

**Fase 1: Novos protocolos + tipos (zero breaking)**
- Criar `AIService.swift`, `ModelPolicy.swift`, `ProviderResolver.swift`
- Criar `AIFeatureRequest` (não substitui AIRequest ainda)
- Adicionar `model_policy`, `provider_templates`, `api_templates`, `agent_modes` ao `ai_config.json`
- **Validar:** build compila, 27 testes passam

**Fase 2: Implementações concretas**
- `JSONConfigProvider` — adapter sobre AIConfigService existente
- `HealthAwareResolver` — absorve ProviderRouter + ActiveProviderManager
- `TieredModelPolicy` — motor de rules do JSON
- `AgentOrchestrator` — unifica AgentLoop + Pipeline
- `APICallTool` — tool genérica de API
- **Validar:** build compila, coexistência com código antigo

**Fase 3: Migrar call sites (um por um)**
- Ordem: ChatViewModel → ContentPipelineService → AnalysisService → AnalysisSkillService → GraphEdgeService → ProjectIngestionPipeline → ProjectConversionService → ContentExtractionService → ShellInterpreter
- Cada migração: substituir ProviderRouter + AIConfigService → AIService.send()
- Cada bypass é automaticamente corrigido na migração
- **Validar:** testes + build após cada call site

**Fase 4: Remover código antigo**
- 🗑️ ProviderRouter.swift
- 🗑️ ActiveProviderManager.swift → ActiveProviderStore
- 🗑️ ProviderTemplates.swift
- 🗑️ AgentLoop.resolveModel()
- 🗑️ ModelResolver
- 🗑️ AIRequest → AIFeatureRequest
- **Validar:** todos os 27 testes passam

**Fase 5: Device validation**
- Build → Deploy → Test no iPhone 14 Plus
- Testar: chat streaming, pipeline, análise, visão, embeddings
- Testar: offline fallback, budget thresholds, user tier override
- Testar: adição de provider novo, adição de API nova
- **Validar:** `make all` passa no device

---

## O Que Não Está Neste Spec

- UI visual redesign (cores, spacing, animações) — apenas estrutura de telas
- App Intents / Siri integration
- On-device LLM inference (llama.cpp)
- Semantic search UI wiring
