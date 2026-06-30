# Share Extension Redesign — Importação Nativa de Conteúdo

**Data:** 2026-06-30
**Status:** Design aprovado
**JIRA:** KAN-XX (a criar)

## Resumo

Redesenhar a Share Extension do Wawa Note para seguir as diretrizes da Apple: processamento autônomo dentro da extensão, SwiftData compartilhado via App Group, e framework `WawaNoteCore` contendo toda lógica reutilizável. Suporte a todos os tipos de conteúdo relevantes: áudio, vídeo, imagem, documentos, URLs e texto.

## Motivação

### Problema atual
- A extensão usa `openURL("wawanote://import")` para abrir o app principal — **não suportado pela Apple**
- Frágil no iOS 18+, risco de rejeição na App Store
- `NSExtensionContext.open(_:completionHandler:)` explicitamente não funciona em Share Extensions (só Today Widgets e iMessage)
- Só suporta audio, movie, file — sem imagens, URLs ou texto
- Sem preview ou feedback visual na extensão
- Lógica de importação duplicada (extensão copia raw, app processa)

### Objetivo
- Extensão funcional e autônoma que cria `KnowledgeItem` diretamente no banco compartilhado
- Código de importação unificado via framework `WawaNoteCore`
- UX fluida: preview → import → confirmação → dismiss
- Zero dependência de abrir o app principal para completar a importação

## Decisões de Design

| Decisão | Escolha | Justificativa |
|---------|---------|---------------|
| Abrir app principal? | Não — extensão autônoma | Apple não suporta; risco App Store |
| Tipos de conteúdo | Todos (áudio, vídeo, imagem, docs, URL, texto) | Cobrir 100% dos casos de uso de share |
| Processamento na extensão | Leve (copy + criar item) | Timeout de 25s; pipeline pesado no app |
| Compartilhar código | Embedded framework `WawaNoteCore` | Sem duplicação, manutenível |
| UI da extensão | SwiftUI | Alinhada com o app principal |
| Persistência | SwiftData via App Group | Fonte única de verdade |

## Arquitetura

### Diagrama de componentes

```
┌──────────────────────────────────────────────────────────┐
│                    WawaNoteCore.framework                 │
│                                                          │
│  Models/          Services/         Importers/           │
│  ─────────        ─────────         ─────────            │
│  KnowledgeItem    ImportRouter      PlainTextImporter    │
│  ProjectModels    FormatImporter    MarkdownImporter     │
│  ChatModels       AudioImportSvc    JSONImporter         │
│  CrossRefModels   FileArtifactStore PDFImporter          │
│                   SharedContainer   HTMLImporter         │
│                                     RTFImporter          │
│  Extensions/                        SRTImporter          │
│  ──────────                         ICSImporter          │
│  UTType+Helpers                     URLImporter (NOVO)   │
│  String+Sanitization                                     │
└──────────────┬───────────────────────────────────────────┘
               │ links em ambos targets
       ┌───────┴───────┐
       │               │
┌──────▼──────┐ ┌──────▼──────────────┐
│  wawa-note  │ │  wawa-note-share    │
│  (app)      │ │  (appex)            │
│             │ │                     │
│  Pipeline   │ │  ShareViewController│
│  AgentLoop  │ │  ShareExtensionView │
│  Calendar   │ │  ShareExtViewModel  │
│  Spotlight  │ │                     │
│  Providers  │ │  (sem acesso a:     │
│  UI completa│ │   providers, LLM,   │
│             │ │   calendário, etc)  │
└──────┬──────┘ └──────┬──────────────┘
       │               │
       └───────┬───────┘
               │ leitura/escrita
┌──────────────▼──────────────────────────────────────────┐
│              App Group (group.com.wawa-note)             │
│                                                          │
│  WawaNote.sqlite          ← SwiftData compartilhado      │
│  files/<itemID>/          ← Arquivos importados          │
│  tmp/                     ← Temp files                   │
└──────────────────────────────────────────────────────────┘
```

### O que vai para o framework vs fica no app

| Componente | Framework | App Principal | Justificativa |
|------------|-----------|---------------|---------------|
| Modelos SwiftData | ✅ | ✅ | Precisam ser visíveis em ambos |
| FormatImporter + implementações | ✅ | ✅ | Usados pela extensão e app |
| ImportRouter | ✅ | ✅ | Roteamento unificado |
| FileArtifactStore (App Group) | ✅ | ✅ | Storage compartilhado |
| AudioImportService | ✅ | ✅ | Metadados + cópia de áudio |
| ContentExtractionService | ❌ | ✅ | OCR, transcrição, URL fetch (APIs pesadas) |
| ContentPipelineService | ❌ | ✅ | Usa LLM providers (bloqueado em extensão) |
| ProcessingQueueService | ❌ | ✅ | Gerencia fila de jobs |
| AgentLoop + Tools | ❌ | ✅ | Chat + tool calling |
| CalendarSyncService | ❌ | ✅ | Acessa EKEventStore |
| SpotlightIndexService | ❌ | ✅ | CoreSpotlight APIs |
| AIProvider + implementações | ❌ | ✅ | API keys via Keychain |
| TranscriptionEngine | ❌ | ✅ | Apple Speech / Remote Whisper |

## Fluxo Detalhado

### 1. Usuário compartilha conteúdo → Extensão abre

```
WhatsApp/Safari/Fotos/etc → Share Sheet → "Wawa Note" → Extensão inicia
```

### 2. ShareExtensionViewModel.loadItems()

```
extensionContext.inputItems (NSExtensionItem[])
    ↓ itera
attachments (NSItemProvider[])
    ↓ para cada provider, testa em ordem de prioridade:
    
1. hasItemConformingToTypeIdentifier(.audio)     → loadFileRepresentation → KnowledgeItemType.audio
2. hasItemConformingToTypeIdentifier(.movie)     → loadFileRepresentation → KnowledgeItemType.audio (com vídeo)
3. hasItemConformingToTypeIdentifier(.image)     → loadFileRepresentation → KnowledgeItemType.image
4. hasItemConformingToTypeIdentifier(.fileURL)   → loadFileRepresentation → detecta formato via ImportRouter
5. hasItemConformingToTypeIdentifier(.url)       → loadItem(for: .url)    → KnowledgeItemType.webBookmark
6. hasItemConformingToTypeIdentifier(.plainText) → loadItem(for: .plainText) → KnowledgeItemType.note
```

### 3. Processamento por tipo

**Áudio / Vídeo:**
1. `loadFileRepresentation(for: type)` → URL temporário
2. `AudioImportService.extractMetadata(url:)` → duração, formato, tamanho
3. Copia para `AppGroup/files/<itemID>/original.<ext>`
4. Cria `KnowledgeItem(type: .audio, status: .draft)`
5. `isImported = true`, `importSourceApp = bundleID do app origem`

**Imagem:**
1. `loadFileRepresentation(for: .image)` → URL temporário
2. Extrai dimensões, formato
3. Copia para `AppGroup/files/<itemID>/original.<ext>`
4. Cria `KnowledgeItem(type: .image, status: .draft)`

**Documento (PDF, MD, JSON, etc.):**
1. `loadFileRepresentation(for: .data)` → URL temporário
2. `ImportRouter.importer(for:)` → encontra FormatImporter
3. `importer.importFromURL(url)` → `ImportResult` com KnowledgeItem + artifacts
4. Copia artifacts para `AppGroup/files/<itemID>/`
5. Insere KnowledgeItem no SwiftData compartilhado

**URL (Safari, etc.):**
1. `loadItem(for: .url)` → `URL` object
2. Cria `KnowledgeItem(type: .webBookmark, bodyText: url.absoluteString)`
3. Título = host do URL (ex: "developer.apple.com")
4. **Sem fetch de conteúdo na extensão** — o app principal fará o fetch da página no pipeline (`ContentExtractionService.extractTextFromURL()`)

**Texto selecionado:**
1. `loadItem(for: .plainText)` → `String`
2. Cria `KnowledgeItem(type: .note, bodyText: text)`
3. Título = primeiras 100 chars

### 4. Persistência e finalização

```
context.save()                                          ← SwiftData shared DB
completeRequest(returningItems: nil, completionHandler: nil)  ← dismiss
```

### 5. App principal descobre e processa

```
App abre (onAppear) / volta ao foreground (NotificationCenter)
    ↓
HomeViewModel.discoverImportedItems()
    ↓ query SwiftData: isImported == true AND processingStatus == "draft"
    ↓
para cada item:
    ↓ enqueue no ProcessingQueueService
    ↓ marca status = "queued" para evitar duplo enfileiramento
    ↓ pipeline normal:
        audio → transcrição → análise
        imagem → OCR → análise
        documento → extração de texto → análise
        URL → fetch conteúdo → extração → análise
        texto → análise
```

## UI da Extensão

### Estados

```
┌──────────────────────────────────┐
│  ← Cancel        Wawa Note       │
├──────────────────────────────────┤
│                                  │
│  [ícone do tipo: 🎵/📄/🖼/🔗]    │
│                                  │
│  Nome do arquivo                 │
│  WhatsApp Audio · 2:34 · 3.2MB  │
│                                  │
│  ⬇️ Importando...                │  ← Estado: importing
│                                  │
│  ─── ou ───                     │
│                                  │
│  ✅ Importado!                   │  ← Estado: done (breve, ~1s)
│  Abra o Wawa Note para           │
│  processar e analisar            │
│                                  │
│  ─── ou ───                     │
│                                  │
│  ❌ Formato não suportado        │  ← Estado: error
│  Formatos aceitos: áudio,        │
│  imagem, vídeo, documentos,     │
│  URLs e texto                    │
└──────────────────────────────────┘
```

### ViewModel — Estados

```swift
enum ImportState {
    case loading         // Detectando tipo de conteúdo
    case importing       // Copiando arquivo, criando item
    case done            // Sucesso (auto-dismiss após 1.5s)
    case error(String)   // Falha com mensagem
}
```

## Edge Cases

| Cenário | Comportamento |
|---------|---------------|
| Arquivo >500MB | Verifica `volumeAvailableCapacity` antes de copiar. Erro imediato se insuficiente |
| Múltiplos arquivos (ex: 5 imagens) | Processa sequencial, progresso "2/5". Continua se uma falhar |
| Timeout da extensão (25s) | Arquivos já copiados + `KnowledgeItem.isIncomplete = true`. App principal completa |
| Usuário cancela (`didSelectCancel`) | Remove arquivos temporários, não cria KnowledgeItem |
| Arquivo duplicado | App principal deduplica por hash + sourceURL no pipeline |
| Disco cheio | `volumeAvailableCapacity` <50MB → erro "Espaço insuficiente" |
| Formato não reconhecido | Mostra erro com lista de formatos aceitos. Não cria item |
| Sem permissão de notificação | Sem problema — feedback visual na extensão é suficiente |
| WhatsApp audio "PTT-...opus" | `AudioImportService` já limpa prefixos; renomeia para formato canônico |

## Mudanças no KnowledgeItem

### Novos campos

```swift
// Adicionar ao modelo existente
var importSourceApp: String?    // Bundle ID do app de origem (ex: "net.whatsapp.WhatsApp")
var isIncomplete: Bool          // true = timeout na extensão, arquivo pode estar parcial
var importError: String?        // Mensagem de erro se a importação falhou
```

Campos já existentes que continuam sendo usados:
- `isImported: Bool` — true para itens vindos da extensão
- `importSourceURL: String?` — URL original do arquivo/compartilhamento
- `audioFileRelativePath: String?` — caminho relativo do áudio no App Group
- `bodyText: String?` — usado para texto importado e conteúdo de URL

## Estrutura de diretórios no App Group

```
~/Library/Group Containers/group.com.wawa-note/
├── WawaNote.sqlite                    ← SwiftData
├── files/
│   ├── <uuid-1>/
│   │   └── original.m4a
│   ├── <uuid-2>/
│   │   └── original.jpg
│   └── <uuid-3>/
│       └── original.md
└── tmp/                               ← Limpo periodicamente
```

## Plano de Build (project.yml)

```yaml
targets:
  WawaNoteCore:
    type: framework
    platform: iOS
    deploymentTarget: "17.0"
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.wawa-note.core
      REQUIRE_ONLY_APP_EXTENSION_SAFE_API: "YES"
      TARGETED_DEVICE_FAMILY: "1"
    sources:
      - path: WawaNoteCore/
    # Não tem dependências externas (só Foundation, SwiftData, SwiftUI)

  wawa-note:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    dependencies:
      - target: WawaNoteCore
      - target: wawa-note-share  # Embed Foundation Extensions
    # ... resto igual

  wawa-note-share:
    type: app-extension
    platform: iOS
    deploymentTarget: "17.0"
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.wawa-note.share
    dependencies:
      - target: WawaNoteCore
    sources:
      - path: wawa-note-share/
```

## Plano de Migração

### Fase 1: Criar WawaNoteCore framework
1. Criar target `WawaNoteCore` via XcodeGen
2. Mover modelos SwiftData para o framework
3. Mover `ImportRouter`, `FormatImporter`, todos os importers para o framework
4. Mover `AudioImportService`, `FileArtifactStore` para o framework
5. Criar `SharedContainer` e `URLImporter` no framework
6. Ajustar imports no app principal (`import WawaNoteCore`)
7. Build e testar que app principal continua funcionando

### Fase 2: Nova Share Extension
1. Reescrever `ShareViewController` como UIViewController + UIHostingController
2. Criar `ShareExtensionView` (SwiftUI) + `ShareExtensionViewModel`
3. Atualizar `Info.plist` com nova activation rule
4. Implementar fluxo completo: load → detect → copy → create item → dismiss
5. Implementar `URLImporter` no framework

### Fase 3: App principal — descoberta e processamento
1. Adicionar `discoverImportedItems()` no `HomeViewModel`
2. Remover `scanSharedDirectoryAndImport()` antigo
3. Remover `wawanote://import` URL scheme handler
4. Adicionar novos campos no `KnowledgeItem`
5. Testar fluxo completo end-to-end

### Fase 4: Testes e validação
1. Testar share de áudio (WhatsApp → Wawa Note)
2. Testar share de imagem (Fotos → Wawa Note)
3. Testar share de URL (Safari → Wawa Note)
4. Testar share de texto (Notes → Wawa Note)
5. Testar share de documento (Files → Wawa Note)
6. Testar edge cases: arquivo grande, múltiplos arquivos, cancelamento, timeout
7. Testar no dispositivo físico (iPhone 14 Plus)

## Riscos e Mitigações

| Risco | Probabilidade | Impacto | Mitigação |
|-------|---------------|---------|-----------|
| SwiftData corrompido por acesso concorrente | Baixa | Alto | WAL mode padrão; extensão só escreve itens novos; testes de stress |
| Framework quebra build do app principal | Média | Alto | Migração incremental; cada passo testado separadamente |
| Timeout em arquivos grandes | Média | Médio | Verificação de espaço; `isIncomplete` flag; app principal completa |
| Rejeição na App Store (URL scheme) | Zero | — | Removemos o `openURL` da extensão; abordagem 100% suportada |

## Referências

- [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/index.html)
- [NSItemProvider — loadFileRepresentation](https://developer.apple.com/documentation/foundation/nsitemprovider)
- [NSExtensionContext — openURL](https://developer.apple.com/documentation/foundation/nsextensioncontext/1416791-openurl) (explicitamente exclui Share Extensions)
- Apple Developer Forums: [Supported public API to open containing iOS app from Share Extension](https://developer.apple.com/forums/thread/824629)
- [Sharing Data in Share Extensions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
