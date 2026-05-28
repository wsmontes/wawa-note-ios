# On-Device LLM Plan — Wawa Note

**Branch:** wawa-note-LLM-local
**Date:** 2026-05-27
**Objective:** Run summarization, task extraction, and semantic search entirely on-device with no cloud dependency.

---

## 1. Architecture Decision: How to ship models

### Decision: Download on first use, not bundled in IPA

**Why:**

| Option | IPA Size | User Experience | Verdict |
|---|---|---|---|
| Bundle in app | +700 MB | Instant, but huge download | ❌ Bad for conversion, App Store cellular limit is 200 MB |
| Download on first launch | +0 MB | User waits once (~2-5 min on WiFi) | ✅ Best balance |
| Hybrid | +150 MB | Tiny model bundled, optional bigger model | 🔶 Complex, defer |

**Model storage location:** `Application Support/models/` — not backed up to iCloud, survives app updates, clearable by system if low on disk.

### Models to download

| Model | File | Size | Purpose |
|---|---|---|---|
| Llama 3.2 1B | `Llama-3.2-1B-Instruct-Q4_K_M.gguf` | ~500 MB | Summarization, task extraction, structured JSON output |
| EmbeddingGemma-300M | `embeddinggemma-300m-Q4_K_M.gguf` | ~200 MB | Semantic search embeddings |

**Source:** Hugging Face — free download, no auth required for these public models.

---

## 2. Component Architecture

```
UI Layer:
  SettingsView  ←  ModelDownloadButton (progress bar, status)
  AppStatusBadge "LLM Ready" / "Downloading model..."

Domain Layer:
  ModelDownloadService   ← downloads GGUF from Hugging Face
  ModelRegistry          ← tracks which models are installed, versions
  LocalLLMProvider       ← implements AIProvider protocol using llama.cpp
  LocalEmbeddingProvider ← implements embed() using llama.cpp

Framework Layer:
  swift-llama (Swift Package) ← wraps llama.cpp + Metal GPU
    ├── LlamaModel (loads GGUF, runs inference)
    ├── LlamaContext (session state, KV cache)
    └── AsyncThrowingStream<String> (token streaming)

Storage Layer:
  Application Support/models/
    ├── Llama-3.2-1B-Instruct-Q4_K_M.gguf  (500 MB)
    ├── embeddinggemma-300m-Q4_K_M.gguf    (200 MB)
    └── models.json                         (registry metadata)
```

---

## 3. Download Flow

```
User opens Settings → "Local AI Models" section
  ├── "Llama 3.2 1B" row → shows [ Download (500 MB) ] button
  ├── "EmbeddingGemma-300M" row → shows [ Download (200 MB) ] button
  └── Status: "No models installed. Download to enable on-device AI."

Tap Download:
  1. ModelDownloadService.download(model:)
  2. URLSession background download with progress
     → https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf
  3. SHA256 integrity check
  4. Move to Application Support/models/
  5. ModelRegistry registers model + version
  6. UI updates: "Llama 3.2 1B — Installed ✓"
```

### Hugging Face URLs

```
LLM:
  https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf

Embedding:
  https://huggingface.co/google/embeddinggemma-300m-GGUF/resolve/main/embeddinggemma-300m-Q4_K_M.gguf
```

Both are free, public, no auth required.

---

## 4. Model Registry

```swift
// Stored as JSON in Application Support/models/models.json
struct ModelRegistry: Codable {
    var models: [String: ModelEntry]  // keyed by modelId
}

struct ModelEntry: Codable {
    let modelId: String           // "llama-3.2-1b"
    let fileName: String          // "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    let version: String           // "1.0"
    let sizeBytes: Int64          // 524288000
    let sha256: String            // integrity hash
    let downloadedAt: Date
    var isActive: Bool
}

// Key methods
func isInstalled(modelId: String) -> Bool
func localURL(for modelId: String) -> URL?
func markInstalled(modelId: String, entry: ModelEntry) throws
func markUninstalled(modelId: String) throws
```

---

## 5. LocalLLMProvider — AIProvider conformance

```swift
final class LocalLLMProvider: AIProvider {
    let id = "local-llm"
    let displayName = "On-Device (Llama 3.2 1B)"
    let capabilities = AIProviderCapabilities(
        supportsStreaming: true,
        supportsAudio: false,
        supportsTools: false,
        supportsEmbeddings: false  // handled by LocalEmbeddingProvider
    )

    private let model: LlamaModel  // swift-llama
    private var context: LlamaContext?

    func send(_ request: AIRequest) async throws -> AIResponse {
        let prompt = buildPrompt(from: request.messages)
        let generated = try await model.generate(
            prompt: prompt,
            maxTokens: request.maxTokens ?? 1024,
            temperature: request.temperature ?? 0.7
        )
        return AIResponse(content: generated, usage: ...)
    }

    func stream(_ request: AIRequest) async throws -> AsyncThrowingStream<AIChunk, Error> {
        // AsyncThrowingStream from swift-llama token stream
    }
}
```

---

## 6. LocalEmbeddingProvider

```swift
final class LocalEmbeddingProvider {
    private let model: LlamaModel  // EmbeddingGemma

    func embed(_ text: String) async throws -> [Float] {
        // Use swift-llama embedding API
        // EmbeddingGemma outputs 256-dim vectors (configurable)
        return try await model.embed(text: text, dimensions: 256)
    }
}
```

---

## 7. Integration with existing code

### Changes to AIProvider protocol

No changes needed! `AIProvider` already supports:
```swift
func send(_ request: AIRequest) async throws -> AIResponse
func stream(_ request: AIRequest) async throws -> AsyncThrowingStream<AIChunk, Error>
func embed(_ text: String, model: String) async throws -> [Float]
```

`LocalLLMProvider` implements all three using llama.cpp locally.

### Changes to ProviderPickerView

Add a "Local AI" section showing:
- Llama 3.2 1B — [Installed ✓] or [Download (500 MB)]
- EmbeddingGemma — [Installed ✓] or [Download (200 MB)]

### Changes to SemanticSearchService

Currently uses `provider.embed()`. With local embedding provider:
```swift
// Before: cloud API call
let queryVector = try await provider.embed(query, model: "text-embedding-3-small")

// After: local embedding
let queryVector = try await localEmbeddingProvider.embed(query)
```

---

## 8. Implementation Order

### Phase 1 — Swift Package + Model Manager (Day 1-2)
- [ ] Add `swift-llama` Swift Package to project
- [ ] Create `ModelDownloadService` (URLSession download + SHA256)
- [ ] Create `ModelRegistry` (install/uninstall/query)
- [ ] Add `Application Support/models/` directory
- [ ] UI: download button in Settings with progress

### Phase 2 — LocalLLMProvider (Day 3-4)
- [ ] Implement `LocalLLMProvider` conforming to `AIProvider`
- [ ] Prompt template for Llama 3.2 1B (structured JSON output)
- [ ] Test summarization + task extraction with real meeting transcript
- [ ] Integration with `AnalysisService`

### Phase 3 — LocalEmbeddingProvider (Day 4-5)
- [ ] Implement `LocalEmbeddingProvider` using EmbeddingGemma
- [ ] Replace cloud embedding calls in `SemanticSearchService`
- [ ] Replace cloud embedding calls in `EmbeddingPipelineService`
- [ ] Fallback to 256-dim vectors throughout

### Phase 4 — Polish (Day 5-6)
- [ ] Model update mechanism (re-download when new version available)
- [ ] "Delete Model" to free space
- [ ] Offline badge in UI ("On-Device" vs "Cloud")
- [ ] Error handling: model not downloaded, corrupted, etc.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Llama 3.2 1B too slow on iPhone 14 Plus | Fallback to Qwen3 0.6B (378 MB, faster but lower quality) |
| EmbeddingGemma-300M quality insufficient | Keep cloud embedding as optional fallback |
| swift-llama API changes | Pin version; it's actively maintained |
| Model download fails mid-way | URLSession resume support, retry button |
| 700 MB too much for 6 GB RAM | Only load one model at a time; unload after use |

---

## 10. Model Unloading Strategy

Only load ONE model at a time to stay within RAM budget:
- When LLM inference runs: load Llama 3.2 1B, unload EmbeddingGemma
- When semantic search runs: load EmbeddingGemma, unload LLM
- Models unloaded immediately after inference completes
- `LlamaContext` freed, model stays on disk for next use

---

## References

- [swift-llama](https://github.com/profclaw/swift-llama) — Swift Package for llama.cpp on Apple platforms
- [Llama 3.2 1B Instruct GGUF](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF) — Quantized GGUF files
- [EmbeddingGemma](https://developers.googleblog.com/introducing-embeddinggemma/) — Google's on-device embedding model
- [Silo](https://github.com/stevederico/silo) — Reference iOS app using llama.cpp locally
