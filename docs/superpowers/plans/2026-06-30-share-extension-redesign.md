# Share Extension Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesenhar a Share Extension com framework WawaNoteCore, SwiftData compartilhado via App Group, suporte a todos os tipos de conteúdo (áudio, vídeo, imagem, documentos, URLs, texto), sem depender de abrir o app principal.

**Architecture:** Embedded framework `WawaNoteCore` contendo modelos SwiftData, importers, e serviços compartilhados. Extensão e app principal linkam o mesmo framework. Persistência via SwiftData no App Group container. Extensão faz processamento leve (copy + criar item), app principal executa pipeline pesado (transcrição, análise LLM).

**Tech Stack:** Swift 6.0, SwiftUI, SwiftData, App Groups, iOS 17.0+, Xcode 26.5, XcodeGen

## Global Constraints

- iOS 17.0+ deployment target
- Swift 6.0 language mode
- REQUIRE_ONLY_APP_EXTENSION_SAFE_API = YES no framework
- Sem APIs bloqueadas em extensões (sem EKEventStore, CoreSpotlight, AVSpeechSynthesizer, etc.)
- App Group: `group.com.wawa-note`
- Bundle ID prefix: `com.wawa-note`
- Development team: `955573A4YH`
- XcodeGen para geração de projeto (NÃO editar project.pbxproj manualmente)
- SwiftData com WAL mode (padrão) para concorrência entre processos
- Extensão NUNCA abre o app principal (sem `openURL`, sem `NSExtensionContext.open`)
- Sempre usar `AIConfigService.shared.requestParams(for:model:)` para parâmetros de AI (não aplicável à extensão)

---

## File Structure

```
WawaNoteCore/                          ← NOVO: embedded framework
├── Models/
│   ├── KnowledgeItem.swift             ← MOVIDO de wawa-note/Domain/Models/
│   ├── ProjectModels.swift             ← MOVIDO
│   ├── ChatModels.swift                ← MOVIDO
│   └── CrossReferenceModels.swift      ← MOVIDO
├── Services/
│   ├── ImportRouter.swift              ← MOVIDO de wawa-note/Ecosystem/Import/
│   ├── FormatImporter.swift            ← MOVIDO
│   ├── AudioImportService.swift        ← MOVIDO de wawa-note/Domain/Services/
│   └── SharedContainer.swift           ← NOVO: App Group URLs + ModelContainer factory
├── Importers/
│   ├── PlainTextImporter.swift         ← MOVIDO de wawa-note/Ecosystem/Import/Importers/
│   ├── MarkdownImporter.swift          ← MOVIDO
│   ├── JSONImporter.swift              ← MOVIDO
│   ├── PDFImporter.swift               ← MOVIDO
│   ├── HTMLImporter.swift              ← MOVIDO
│   ├── RTFImporter.swift               ← MOVIDO
│   ├── SRTImporter.swift               ← MOVIDO
│   ├── ICSImporter.swift               ← MOVIDO
│   └── URLImporter.swift               ← NOVO
├── Storage/
│   └── FileArtifactStore.swift         ← MOVIDO de wawa-note/Storage/
└── Extensions/
    ├── UTType+ShareHelpers.swift       ← NOVO: UTType helpers para Share Extension
    └── String+Sanitization.swift       ← NOVO: filename sanitization

wawa-note-share/                        ← MODIFICADO
├── ShareViewController.swift           ← REESCRITO: UIViewController + UIHostingController
├── ShareExtensionView.swift            ← NOVO: SwiftUI root view
├── ShareExtensionViewModel.swift       ← NOVO: @Observable, lógica de importação
├── Info.plist                          ← MODIFICADO: nova activation rule
└── wawa-note-share.entitlements        ← mantido (já tem App Groups)

wawa-note/
├── UI/Home/HomeView.swift              ← MODIFICADO: discoverImportedItems, remove scanSharedDirectory
├── Domain/Models/KnowledgeItem.swift   ← MODIFICADO: 3 novos campos
├── Ecosystem/Import/                   ← ESVAZIADO (movido para framework)
├── Domain/Services/AudioImportService.swift ← ESVAZIADO (movido)
└── Storage/FileArtifactStore.swift     ← ESVAZIADO (movido)

project.yml                             ← MODIFICADO: novo target WawaNoteCore
```

---

### Task 1: Criar target WawaNoteCore no project.yml

**Files:**
- Modify: `project.yml:38-55`

**Interfaces:**
- Consumes: Nada (primeiro task)
- Produces: target `WawaNoteCore` compilável como framework iOS

- [ ] **Step 1: Adicionar target WawaNoteCore ao project.yml**

```yaml
targets:
  WawaNoteCore:
    type: framework
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: WawaNoteCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.wawa-note.core
        REQUIRE_ONLY_APP_EXTENSION_SAFE_API: "YES"
        TARGETED_DEVICE_FAMILY: "1"
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: "YES"
        DEVELOPMENT_TEAM: 955573A4YH
        CODE_SIGN_STYLE: Automatic
```

Inserir este target ANTES do target `wawa-note` (ordem alfabética não importa, mas targets com dependências devem ser definidos antes de quem os consome, ou o XcodeGen resolve sozinho). Vamos inserir entre a linha 37 e 38 do project.yml atual — logo após a definição de `targets:` e antes de `wawa-note:`.

No arquivo `project.yml`, localizar a linha `targets:` (linha 38). Inserir o bloco `WawaNoteCore` como primeiro target.

- [ ] **Step 2: Adicionar dependência do framework nos targets existentes**

No target `wawa-note` (linha ~52), adicionar `- target: WawaNoteCore` à lista de `dependencies`:

```yaml
    dependencies:
      - target: WawaNoteCore      # ← NOVA linha
      - target: wawa-note-watch
      - target: wawa-note-share
      - package: Yams
```

No target `wawa-note-share` (linha ~86), adicionar `- target: WawaNoteCore`:

```yaml
    dependencies:
      - target: WawaNoteCore      # ← NOVA linha
    settings:
```

- [ ] **Step 3: Criar diretório do framework e arquivo placeholder**

```bash
mkdir -p WawaNoteCore/Models
mkdir -p WawaNoteCore/Services
mkdir -p WawaNoteCore/Importers
mkdir -p WawaNoteCore/Storage
mkdir -p WawaNoteCore/Extensions
```

Criar `WawaNoteCore/Placeholder.swift` (necessário para o target compilar com diretório vazio):

```swift
// WawaNoteCore/Placeholder.swift
// Temporary placeholder — will be removed when real files are moved in.
```

- [ ] **Step 4: Gerar projeto Xcode e verificar que compila**

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios
xcodegen generate
```

Abrir `wawa-note.xcodeproj` no Xcode, selecionar scheme `WawaNoteCore`, build (⌘B). Deve compilar sem erros.

- [ ] **Step 5: Verificar que o target principal continua compilando**

Selecionar scheme `wawa-note`, build (⌘B). Deve compilar sem erros (o framework está vazio, mas linka corretamente).

- [ ] **Step 6: Commit**

```bash
git add project.yml WawaNoteCore/
git commit -m "feat: add WawaNoteCore framework target

- New embedded framework target for shared code between app and extension
- Added as dependency to both wawa-note and wawa-note-share targets
- REQUIRE_ONLY_APP_EXTENSION_SAFE_API = YES

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Mover modelos SwiftData para WawaNoteCore

**Files:**
- Move: `wawa-note/Domain/Models/KnowledgeItem.swift` → `WawaNoteCore/Models/KnowledgeItem.swift`
- Move: `wawa-note/Domain/Models/ProjectModels.swift` → `WawaNoteCore/Models/ProjectModels.swift`
- Move: `wawa-note/Domain/Models/ChatModels.swift` → `WawaNoteCore/Models/ChatModels.swift`
- Move: `wawa-note/Domain/Models/CrossReferenceModels.swift` → `WawaNoteCore/Models/CrossReferenceModels.swift`
- Delete: `WawaNoteCore/Placeholder.swift`
- Modify: `wawa-note/UI/Home/HomeView.swift` — adicionar `import WawaNoteCore`
- Modify: `wawa-note/Domain/Services/ContentPipelineService.swift` — adicionar `import WawaNoteCore`
- Modify: `wawa-note/Domain/Services/KnowledgeItemService.swift` — adicionar `import WawaNoteCore`
- Modify: todos os arquivos que importavam os modelos movidos

**Interfaces:**
- Consumes: Task 1 (WawaNoteCore target)
- Produces: `KnowledgeItem`, `Project`, `TaskItem`, `Person`, `GraphEdge`, `Entity`, `ChatMessage`, `CrossReferenceResult` acessíveis via `import WawaNoteCore`

- [ ] **Step 1: Mover arquivos de modelo**

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios

# Mover modelos para o framework
mv wawa-note/Domain/Models/KnowledgeItem.swift WawaNoteCore/Models/
mv wawa-note/Domain/Models/ProjectModels.swift WawaNoteCore/Models/
mv wawa-note/Domain/Models/ChatModels.swift WawaNoteCore/Models/
mv wawa-note/Domain/Models/CrossReferenceModels.swift WawaNoteCore/Models/

# Remover placeholder
rm WawaNoteCore/Placeholder.swift

# Se os diretórios antigos ficarem vazios, removê-los também
rmdir wawa-note/Domain/Models 2>/dev/null || true
```

- [ ] **Step 2: Atualizar source paths no project.yml**

O target `wawa-note` tem `sources: - path: wawa-note`. Isso automaticamente inclui todos os arquivos sob `wawa-note/`, então os arquivos movidos para fora deixarão de ser compilados no target principal. VERIFICAR se o target `wawa-note` não tem referências explícitas a arquivos de modelo individuais. Como usa `path: wawa-note` com exclusão só de `.DS_Store`, está correto — os arquivos movidos saem automaticamente.

O target `WawaNoteCore` tem `sources: - path: WawaNoteCore` — os arquivos movidos entram automaticamente.

- [ ] **Step 3: Adicionar `import WawaNoteCore` nos arquivos do app principal que usam os modelos**

Listar todos os arquivos que referenciam `KnowledgeItem`, `Project`, `TaskItem`, etc.:

```bash
grep -rl "KnowledgeItem\|ProjectModels\|ChatModels\|CrossReferenceModels" wawa-note/ --include="*.swift" | grep -v "^wawa-note/Domain/Models/"
```

Para cada arquivo encontrado, adicionar `import WawaNoteCore` logo após os imports existentes. Exemplo nos arquivos principais:

```swift
// HomeView.swift — adicionar após os imports existentes
import WawaNoteCore
```

```swift
// ContentPipelineService.swift
import WawaNoteCore
```

```swift
// KnowledgeItemService.swift
import WawaNoteCore
```

```swift
// ContentView.swift
import WawaNoteCore
```

```swift
// WawaNoteApp.swift
import WawaNoteCore
```

- [ ] **Step 4: Verificar se há referências de modelo no target wawa-note-watch**

O target watchOS inclui `wawa-note/Connectivity/WatchMessageTypes.swift` e `wawa-note/Utilities/Logging.swift`. Nenhum desses referencia modelos SwiftData. Verificar com:

```bash
grep -l "KnowledgeItem\|import SwiftData" wawa-note/Connectivity/WatchMessageTypes.swift wawa-note/Utilities/Logging.swift
```

Se não houver matches, o watch target não precisa de `import WawaNoteCore`. Caso contrário, precisará adicionar o framework como dependência do target watch também.

- [ ] **Step 5: Gerar projeto e compilar**

```bash
xcodegen generate
```

Build do scheme `WawaNoteCore` (⌘B) — deve compilar.
Build do scheme `wawa-note` (⌘B) — espera-se erros de compilação em arquivos que ainda não adicionaram `import WawaNoteCore`. Corrigir cada um adicionando o import.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: move SwiftData models to WawaNoteCore framework

- KnowledgeItem, ProjectModels, ChatModels, CrossReferenceModels
- Added import WawaNoteCore to all consuming files
- Framework compiles independently with REQUIRE_ONLY_APP_EXTENSION_SAFE_API

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Mover ImportRouter, FormatImporter, e importers para WawaNoteCore

**Files:**
- Move: `wawa-note/Ecosystem/Import/ImportRouter.swift` → `WawaNoteCore/Services/ImportRouter.swift`
- Move: `wawa-note/Ecosystem/Import/FormatImporter.swift` → `WawaNoteCore/Services/FormatImporter.swift`
- Move: `wawa-note/Ecosystem/Import/Importers/PlainTextImporter.swift` → `WawaNoteCore/Importers/`
- Move: `wawa-note/Ecosystem/Import/Importers/MarkdownImporter.swift` → `WawaNoteCore/Importers/`
- Move: `wawa-note/Ecosystem/Import/Importers/JSONImporter.swift` → `WawaNoteCore/Importers/`
- Move: `wawa-note/Ecosystem/Import/Importers/PDFImporter.swift` → `WawaNoteCore/Importers/`
- Move: `wawa-note/Ecosystem/Import/Importers/HTMLImporter.swift` → `WawaNoteCore/Importers/`
- Move: `wawa-note/Ecosystem/Import/Importers/RTFImporter.swift` → `WawaNoteCore/Importers/`
- Move: `wawa-note/Ecosystem/Import/Importers/SRTImporter.swift` → `WawaNoteCore/Importers/`
- Move: `wawa-note/Ecosystem/Import/Importers/ICSImporter.swift` → `WawaNoteCore/Importers/`
- Modify: `wawa-note/UI/Home/HomeView.swift` — atualizar caminho de init do ImportRouter
- NOT Move: `AnarlogImporter.swift` e `MeetilyImporter.swift` — estes ficam no app principal (dependem de parsing especializado que não é extension-safe)

**Interfaces:**
- Consumes: Task 2 (modelos no framework)
- Produces: `ImportRouter`, `FormatImporter`, todos os importers padrão disponíveis via `import WawaNoteCore`

- [ ] **Step 1: Mover arquivos de import**

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios

# Mover router + protocolo
mv wawa-note/Ecosystem/Import/ImportRouter.swift WawaNoteCore/Services/
mv wawa-note/Ecosystem/Import/FormatImporter.swift WawaNoteCore/Services/

# Mover importers padrão (NÃO Anarlog nem Meetily)
mv wawa-note/Ecosystem/Import/Importers/PlainTextImporter.swift WawaNoteCore/Importers/
mv wawa-note/Ecosystem/Import/Importers/MarkdownImporter.swift WawaNoteCore/Importers/
mv wawa-note/Ecosystem/Import/Importers/JSONImporter.swift WawaNoteCore/Importers/
mv wawa-note/Ecosystem/Import/Importers/PDFImporter.swift WawaNoteCore/Importers/
mv wawa-note/Ecosystem/Import/Importers/HTMLImporter.swift WawaNoteCore/Importers/
mv wawa-note/Ecosystem/Import/Importers/RTFImporter.swift WawaNoteCore/Importers/
mv wawa-note/Ecosystem/Import/Importers/SRTImporter.swift WawaNoteCore/Importers/
mv wawa-note/Ecosystem/Import/Importers/ICSImporter.swift WawaNoteCore/Importers/
```

- [ ] **Step 2: Atualizar ImportRouter no HomeViewModel**

No arquivo `wawa-note/UI/Home/HomeView.swift`, linha ~23, o `ImportRouter` agora é importado do framework. Os importers `AnarlogImporter` e `MeetilyImporter` continuam no app principal (em `wawa-note/Ecosystem/Anarlog/`). Atualizar a inicialização:

```swift
// HomeViewModel (HomeView.swift, ~linha 23)
let importRouter = ImportRouter(importers: [
    AudioImportService(), PlainTextImporter(), MarkdownImporter(),
    JSONImporter(), PDFImporter(), HTMLImporter(), RTFImporter(),
    SRTImporter(), ICSImporter(), AnarlogImporter(), MeetilyImporter(),
])
```

Isso NÃO muda — os importers são instanciados diretamente, e o `ImportRouter` aceita `[any FormatImporter]`. Como `FormatImporter` agora é definido em WawaNoteCore, o `import WawaNoteCore` (adicionado no Task 2) já resolve.

- [ ] **Step 3: Verificar se AnarlogImporter e MeetilyImporter compilam**

Estes importers referenciam `FormatImporter` e `KnowledgeItem` que agora estão em WawaNoteCore. Eles estão em `wawa-note/Ecosystem/Anarlog/`, que faz parte do target principal. Precisam de `import WawaNoteCore`:

```bash
# Verificar se já têm imports
head -5 wawa-note/Ecosystem/Anarlog/AnarlogImporter.swift
head -5 wawa-note/Ecosystem/Anarlog/MeetilyImporter.swift
```

Adicionar `import WawaNoteCore` no topo de cada um se ainda não estiver lá.

- [ ] **Step 4: Gerar projeto e compilar**

```bash
xcodegen generate
```

Build do scheme `WawaNoteCore` (⌘B) — deve compilar.
Build do scheme `wawa-note` (⌘B) — corrigir erros de import até compilar limpo.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: move ImportRouter, FormatImporter, and importers to WawaNoteCore

- All standard importers moved to framework
- AnarlogImporter and MeetilyImporter stay in app (specialized parsing)
- ImportRouter and FormatImporter protocol now in shared framework

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Mover AudioImportService e FileArtifactStore para WawaNoteCore

**Files:**
- Move: `wawa-note/Domain/Services/AudioImportService.swift` → `WawaNoteCore/Services/AudioImportService.swift`
- Move: `wawa-note/Storage/FileArtifactStore.swift` → `WawaNoteCore/Storage/FileArtifactStore.swift`

**Interfaces:**
- Consumes: Task 2, Task 3 (modelos + importers)
- Produces: `AudioImportService`, `FileArtifactStore` disponíveis via `import WawaNoteCore`

- [ ] **Step 1: Mover arquivos**

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios
mv wawa-note/Domain/Services/AudioImportService.swift WawaNoteCore/Services/
mv wawa-note/Storage/FileArtifactStore.swift WawaNoteCore/Storage/
```

- [ ] **Step 2: Atualizar FileArtifactStore para usar App Group**

Verificar se `FileArtifactStore` já usa App Group ou se usa o documents directory do app. O `FileArtifactStore` precisa ser acessível de ambos os processos, então deve usar `SharedContainer.appGroupURL` (criado no Task 5) em vez de `FileManager.default.urls(for: .documentDirectory, ...)`.

Abrir o arquivo movido `WawaNoteCore/Storage/FileArtifactStore.swift` e verificar:

```bash
grep -n "documentDirectory\|appGroup\|group.com.wawa-note\|containerURL" WawaNoteCore/Storage/FileArtifactStore.swift
```

Se usar `documentDirectory`, modificar para usar `SharedContainer.filesURL` (definido no Task 5). Por enquanto, se o FileArtifactStore referenciar `documentDirectory`, vamos adiar essa mudança para o Task 5 onde `SharedContainer` será introduzido.

NOTA: Se `FileArtifactStore` atualmente depende de APIs não disponíveis em extensões, remover essas dependências ou criar versão limitada para extensão. Verificar imports:

```bash
head -10 WawaNoteCore/Storage/FileArtifactStore.swift
```

- [ ] **Step 3: Verificar compatibilidade do AudioImportService**

O `AudioImportService` usa `AVAudioPlayer`, `AVAsset`, `ExtAudioFile`. Todos disponíveis em extensões iOS. Verificar:

```bash
grep -n "import\|AVAudio\|ExtAudioFile\|AVAsset" WawaNoteCore/Services/AudioImportService.swift
```

- [ ] **Step 4: Gerar projeto e compilar**

```bash
xcodegen generate
```

Build do scheme `WawaNoteCore` e `wawa-note`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: move AudioImportService and FileArtifactStore to WawaNoteCore

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Criar SharedContainer, URLImporter, e extensões no framework

**Files:**
- Create: `WawaNoteCore/Services/SharedContainer.swift`
- Create: `WawaNoteCore/Importers/URLImporter.swift`
- Create: `WawaNoteCore/Extensions/UTType+ShareHelpers.swift`
- Create: `WawaNoteCore/Extensions/String+Sanitization.swift`

**Interfaces:**
- Consumes: Task 4 (AudioImportService, FileArtifactStore)
- Produces:
  - `SharedContainer.appGroupURL: URL` — raiz do App Group
  - `SharedContainer.databaseURL: URL` — caminho do WawaNote.sqlite
  - `SharedContainer.filesURL: URL` — diretório files/
  - `SharedContainer.makeModelContainer() throws -> ModelContainer` — factory method
  - `URLImporter: FormatImporter` — importa URLs como webBookmark
  - `UTType.shareableTypes: [UTType]` — tipos suportados pela extensão
  - `String.safeImportFilename(original:) -> String` — sanitização

- [ ] **Step 1: Criar SharedContainer.swift**

```swift
// WawaNoteCore/Services/SharedContainer.swift
import Foundation
import SwiftData

/// Centralized access to App Group shared container paths and ModelContainer factory.
/// Used by both the main app and the Share Extension to access the same data.
enum SharedContainer {
    static let appGroupIdentifier = "group.com.wawa-note"

    static var appGroupURL: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            fatalError("App Group \(appGroupIdentifier) not accessible. Check entitlements.")
        }
        return url
    }

    static var databaseURL: URL {
        appGroupURL.appendingPathComponent("WawaNote.sqlite")
    }

    static var filesURL: URL {
        appGroupURL.appendingPathComponent("files", isDirectory: true)
    }

    static var tmpURL: URL {
        appGroupURL.appendingPathComponent("tmp", isDirectory: true)
    }

    /// Creates a ModelContainer backed by the shared App Group database.
    /// Call this from both the main app and the extension.
    static func makeModelContainer() throws -> ModelContainer {
        let config = ModelConfiguration(url: databaseURL)
        return try ModelContainer(
            for: KnowledgeItem.self,
                 Project.self,
                 TaskItem.self,
                 Person.self,
                 GraphEdge.self,
                 Entity.self,
            configurations: config
        )
    }

    /// Ensure files and tmp directories exist.
    static func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpURL, withIntermediateDirectories: true)
    }

    /// Check available space in the App Group container (bytes).
    static func availableSpace() -> Int64 {
        guard let values = try? appGroupURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else {
            return 0
        }
        return capacity
    }
}
```

- [ ] **Step 2: Criar URLImporter.swift**

```swift
// WawaNoteCore/Importers/URLImporter.swift
import Foundation
import UniformTypeIdentifiers

/// Imports shared URLs (from Safari, etc.) as webBookmark KnowledgeItems.
struct URLImporter: FormatImporter {
    let formatIdentifier = "url"
    let displayName = "URL"
    let supportedUTTypes: [UTType] = [.url]
    let priority = 0

    func canRead(url: URL) -> Bool {
        // URLImporter handles URL objects directly via NSItemProvider,
        // not file URLs. File-based detection returns false.
        false
    }

    func canRead(data: Data) -> Bool {
        // URLs come as objects, not Data.
        false
    }

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let host = url.host ?? url.absoluteString
        let title = host
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let item = KnowledgeItem(
            type: .webBookmark,
            title: title,
            bodyText: url.absoluteString,
            status: .draft
        )
        item.isImported = true
        item.importSourceURL = url.absoluteString

        return ImportResult(knowledgeItem: item, artifacts: [:], warnings: [])
    }
}
```

- [ ] **Step 3: Criar UTType+ShareHelpers.swift**

```swift
// WawaNoteCore/Extensions/UTType+ShareHelpers.swift
import UniformTypeIdentifiers

extension UTType {
    /// Types supported by the Share Extension, in detection priority order.
    static let shareableTypes: [UTType] = [
        .audio,
        .movie,
        .image,
        .fileURL,
        .url,
        .plainText,
    ]

    /// Maps a UTType to the corresponding KnowledgeItemType.
    var knowledgeItemType: KnowledgeItemType? {
        if conforms(to: .audio) { return .audio }
        if conforms(to: .movie) { return .audio }  // movies treated as audio items (transcription)
        if conforms(to: .image) { return .image }
        if conforms(to: .url) { return .webBookmark }
        if conforms(to: .plainText) { return .note }
        if conforms(to: .fileURL) || conforms(to: .data) || conforms(to: .content) {
            // Generic file — needs ImportRouter to determine specific type
            return nil
        }
        return nil
    }
}
```

- [ ] **Step 4: Criar String+Sanitization.swift**

```swift
// WawaNoteCore/Extensions/String+Sanitization.swift
import Foundation

extension String {
    /// Sanitize a filename for safe storage. Prepends a UUID prefix to avoid collisions.
    static func safeImportFilename(original: String) -> String {
        let sanitized = original
            .replacingOccurrences(
                of: "[^a-zA-Z0-9._-]",
                with: "_",
                options: .regularExpression
            )
        return "\(UUID().uuidString)-\(sanitized)"
    }
}
```

- [ ] **Step 5: Gerar projeto e compilar framework**

```bash
xcodegen generate
```

Build scheme `WawaNoteCore` (⌘B). Corrigir quaisquer erros de compilação.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add SharedContainer, URLImporter, and extensions to WawaNoteCore

- SharedContainer: App Group URL management + ModelContainer factory
- URLImporter: imports shared URLs as webBookmark items
- UTType+ShareHelpers: type detection priority ordering
- String+Sanitization: safe filename generation

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Reescrever Share Extension — ViewModel + SwiftUI

**Files:**
- Rewrite: `wawa-note-share/ShareViewController.swift`
- Create: `wawa-note-share/ShareExtensionViewModel.swift`
- Create: `wawa-note-share/ShareExtensionView.swift`
- Modify: `wawa-note-share/Info.plist`

**Interfaces:**
- Consumes: Tasks 1-5 (WawaNoteCore framework completo)
- Produces: Share Extension funcional que detecta, copia, cria KnowledgeItem, e faz dismiss

- [ ] **Step 1: Reescrever ShareViewController.swift como host SwiftUI**

```swift
// wawa-note-share/ShareViewController.swift
import OSLog
import SwiftUI
import UIKit
import WawaNoteCore

private let logger = Logger(subsystem: "com.wawa-note.share", category: "share-extension")

/// Minimal UIViewController that hosts the SwiftUI ShareExtensionView.
/// Required by NSExtensionPrincipalClass — must be a UIViewController subclass.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        guard let extensionContext = extensionContext else {
            logger.error("No extensionContext available")
            return
        }

        let viewModel = ShareExtensionViewModel(extensionContext: extensionContext)
        let rootView = ShareExtensionView(viewModel: viewModel)

        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)
    }
}
```

- [ ] **Step 2: Criar ShareExtensionViewModel.swift**

```swift
// wawa-note-share/ShareExtensionViewModel.swift
import Foundation
import OSLog
import SwiftData
import UniformTypeIdentifiers
import WawaNoteCore

private let logger = Logger(subsystem: "com.wawa-note.share", category: "view-model")

enum ImportState: Equatable {
    case loading
    case importing(fileName: String, progress: String)
    case done(itemCount: Int)
    case error(String)
}

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    @Published var state: ImportState = .loading

    private let extensionContext: NSExtensionContext
    private let router = ImportRouter(importers: [
        AudioImportService(), PlainTextImporter(), MarkdownImporter(),
        JSONImporter(), PDFImporter(), HTMLImporter(), RTFImporter(),
        SRTImporter(), ICSImporter(),
    ])

    init(extensionContext: NSExtensionContext) {
        self.extensionContext = extensionContext
    }

    // MARK: - Load items

    func loadItems() async {
        guard let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            finish(with: .error("No content to import"))
            return
        }

        let providers: [NSItemProvider] = inputItems.compactMap(\.attachments).flatMap { $0 }

        guard !providers.isEmpty else {
            finish(with: .error("No content to import"))
            return
        }

        var importedCount = 0
        var errors: [String] = []

        do {
            try SharedContainer.ensureDirectories()
        } catch {
            finish(with: .error("Cannot access storage: \(error.localizedDescription)"))
            return
        }

        for (index, provider) in providers.enumerated() {
            let progress = providers.count > 1 ? "\(index + 1)/\(providers.count)" : ""
            state = .importing(fileName: "Detecting content...", progress: progress)

            do {
                let item = try await importProvider(provider)
                try await persistItem(item)
                importedCount += 1
            } catch {
                logger.error("Failed to import provider \(index): \(error.localizedDescription)")
                errors.append(error.localizedDescription)
            }
        }

        if importedCount > 0 {
            finish(with: .done(itemCount: importedCount))
        } else {
            let message = errors.first ?? "No supported content found"
            finish(with: .error(message))
        }
    }

    // MARK: - Provider type detection

    private func importProvider(_ provider: NSItemProvider) async throws -> KnowledgeItem {
        // Check types in priority order
        for type in UTType.shareableTypes {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }

            switch type {
            case .audio, .movie:
                return try await importMedia(provider, type: type, itemType: .audio)
            case .image:
                return try await importMedia(provider, type: type, itemType: .image)
            case .fileURL, .data, .content:
                return try await importFile(provider)
            case .url:
                return try await importURL(provider)
            case .plainText:
                return try await importText(provider)
            default:
                continue
            }
        }

        throw ImportError.unsupportedType(provider.registeredTypeIdentifiers)
    }

    // MARK: - Media (audio/video/image)

    private func importMedia(_ provider: NSItemProvider, type: UTType, itemType: KnowledgeItemType) async throws -> KnowledgeItem {
        let url = try await loadFileRepresentation(from: provider, typeIdentifier: type.identifier)
        defer { try? FileManager.default.removeItem(at: url) }

        let originalName = provider.suggestedName ?? url.lastPathComponent
        let item = KnowledgeItem(type: itemType, title: originalName, status: .draft)
        item.isImported = true

        // Extract audio metadata
        if itemType == .audio, let audioService = router.importer(for: url) as? AudioImportService {
            let result = try await audioService.importFromURL(url)
            item.title = result.knowledgeItem.title
            item.audioDuration = result.knowledgeItem.audioDuration
            item.audioFormat = result.knowledgeItem.audioFormat
            item.audioFileSize = result.knowledgeItem.audioFileSize
            // Merge artifacts
            for (key, artifactURL) in result.artifacts {
                let destURL = SharedContainer.filesURL
                    .appendingPathComponent(item.id.uuidString)
                    .appendingPathComponent(artifactURL.lastPathComponent)
                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: artifactURL, to: destURL)
                if key == "audio" {
                    item.audioFileRelativePath = "files/\(item.id.uuidString)/\(artifactURL.lastPathComponent)"
                }
            }
        } else {
            // Copy file to App Group
            let safeName = String.safeImportFilename(original: originalName)
            let itemDir = SharedContainer.filesURL.appendingPathComponent(item.id.uuidString)
            try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
            let destURL = itemDir.appendingPathComponent(safeName)
            try FileManager.default.copyItem(at: url, to: destURL)

            if itemType == .audio {
                item.audioFileRelativePath = "files/\(item.id.uuidString)/\(safeName)"
            } else if itemType == .image {
                item.imageFileRelativePath = "files/\(item.id.uuidString)/\(safeName)"
            }
        }

        item.importSourceURL = url.absoluteString
        return item
    }

    // MARK: - File (document)

    private func importFile(_ provider: NSItemProvider) async throws -> KnowledgeItem {
        let url = try await loadFileRepresentation(from: provider, typeIdentifier: UTType.data.identifier)
        defer { try? FileManager.default.removeItem(at: url) }

        let originalName = provider.suggestedName ?? url.lastPathComponent
        state = .importing(fileName: originalName, progress: "Detecting format...")

        // Try ImportRouter first
        if let importer = router.importer(for: url) {
            let result = try await importer.importFromURL(url)
            let item = result.knowledgeItem
            item.isImported = true
            item.importSourceURL = url.absoluteString

            // Copy artifacts
            let itemDir = SharedContainer.filesURL.appendingPathComponent(item.id.uuidString)
            try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
            for (key, artifactURL) in result.artifacts {
                let destURL = itemDir.appendingPathComponent(artifactURL.lastPathComponent)
                try FileManager.default.copyItem(at: artifactURL, to: destURL)
            }
            return item
        }

        // Fallback: import as plain file
        let safeName = String.safeImportFilename(original: originalName)
        let itemDir = SharedContainer.filesURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        let destURL = itemDir.appendingPathComponent(safeName)
        try FileManager.default.copyItem(at: url, to: destURL)

        let item = KnowledgeItem(type: .note, title: originalName, status: .draft)
        item.isImported = true
        item.importSourceURL = url.absoluteString
        return item
    }

    // MARK: - URL

    private func importURL(_ provider: NSItemProvider) async throws -> KnowledgeItem {
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let urlString = item as? String, let url = URL(string: urlString) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ImportError.unsupportedType(["url"]))
                }
            }
        }

        let urlImporter = URLImporter()
        let result = try await urlImporter.importFromURL(url)
        result.knowledgeItem.isImported = true
        return result.knowledgeItem
    }

    // MARK: - Text

    private func importText(_ provider: NSItemProvider) async throws -> KnowledgeItem {
        let text: String = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let string = item as? String {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(throwing: ImportError.unsupportedType(["public.plain-text"]))
                }
            }
        }

        let title = String(text.prefix(100))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        let item = KnowledgeItem(type: .note, title: title, bodyText: text, status: .draft)
        item.isImported = true
        return item
    }

    // MARK: - Helpers

    private func loadFileRepresentation(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url {
                    // Copy to temp so it survives the completion handler
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)
                    do {
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        continuation.resume(returning: tempURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: ImportError.unsupportedType([typeIdentifier]))
                }
            }
        }
    }

    private func persistItem(_ item: KnowledgeItem) async throws {
        let container = try SharedContainer.makeModelContainer()
        let context = ModelContext(container)
        context.insert(item)
        try context.save()
        logger.info("Persisted item \(item.id) — type: \(item.typeRaw), title: \(item.title)")
    }

    private func finish(with state: ImportState) {
        self.state = state
        if case .done = state {
            // Auto-dismiss after brief confirmation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.extensionContext.completeRequest(returningItems: nil)
            }
        }
    }

    func cancel() {
        extensionContext.cancelRequest(withError: NSError(
            domain: "com.wawa-note.share",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Import cancelled"]
        ))
    }

    func dismissAfterError() {
        extensionContext.completeRequest(returningItems: nil)
    }
}

enum ImportError: LocalizedError {
    case unsupportedType([String])
    case diskFull
    case timeout

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let types):
            "Unsupported content type: \(types.joined(separator: ", "))"
        case .diskFull:
            "Not enough storage space. Please free up space and try again."
        case .timeout:
            "Import took too long. The item may be incomplete."
        }
    }
}
```

- [ ] **Step 3: Criar ShareExtensionView.swift**

```swift
// wawa-note-share/ShareExtensionView.swift
import SwiftUI
import WawaNoteCore

struct ShareExtensionView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .loading:
                    loadingView
                case .importing(let fileName, let progress):
                    importingView(fileName: fileName, progress: progress)
                case .done(let count):
                    doneView(count: count)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancel() }
                }
            }
        }
        .task {
            await viewModel.loadItems()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Preparing...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Importing

    private func importingView(fileName: String, progress: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "arrow.down.doc")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(fileName)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if !progress.isEmpty {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Importing...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done

    private func doneView(count: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Imported!")
                .font(.title2.bold())

            Text("Open Wawa Note to process and analyze")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Import Failed")
                .font(.title2.bold())

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Supported formats: audio, images, video, documents, URLs, and text")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Dismiss") {
                viewModel.dismissAfterError()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Atualizar Info.plist da extensão**

Atualizar `wawa-note-share/Info.plist` — substituir o `NSExtensionActivationRule` atual:

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>NSExtensionActivationRule</key>
        <dict>
            <key>NSExtensionActivationSupportsAudioWithMaxCount</key>
            <integer>1</integer>
            <key>NSExtensionActivationSupportsMovieWithMaxCount</key>
            <integer>1</integer>
            <key>NSExtensionActivationSupportsImageWithMaxCount</key>
            <integer>5</integer>
            <key>NSExtensionActivationSupportsFileWithMaxCount</key>
            <integer>1</integer>
            <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
            <integer>1</integer>
            <key>NSExtensionActivationSupportsText</key>
            <true/>
        </dict>
    </NSExtensionAttributes>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
</dict>
```

- [ ] **Step 5: Gerar projeto e compilar extensão**

```bash
xcodegen generate
```

Build scheme `wawa-note-share` (⌘B). Corrigir erros de compilação.
Build scheme `wawa-note` (⌘B). Deve continuar compilando.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: rewrite Share Extension with SwiftUI and WawaNoteCore

- ShareViewController as UIHostingController bridge
- ShareExtensionViewModel with full type detection and import flow
- ShareExtensionView with 4 states: loading, importing, done, error
- Updated Info.plist: supports audio, video, images, files, URLs, text
- Extension creates KnowledgeItem directly in shared SwiftData

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Adicionar novos campos ao KnowledgeItem

**Files:**
- Modify: `WawaNoteCore/Models/KnowledgeItem.swift`

**Interfaces:**
- Consumes: Task 2 (modelos no framework)
- Produces: `KnowledgeItem.importSourceApp: String?`, `KnowledgeItem.isIncomplete: Bool`, `KnowledgeItem.importError: String?`

- [ ] **Step 1: Adicionar os 3 novos campos**

No arquivo `WawaNoteCore/Models/KnowledgeItem.swift`, localizar os campos existentes `isImported` e `importSourceURL` (~linha 214-215). Adicionar após eles:

```swift
var isImported: Bool = false
var importSourceURL: String?
/// Bundle ID of the source app (e.g., "net.whatsapp.WhatsApp")
var importSourceApp: String?
/// true if the extension timed out before completing the import
var isIncomplete: Bool = false
/// Error message if the import failed in the extension but the item was still created
var importError: String?
```

- [ ] **Step 2: Verificar se há migrations necessárias**

Os novos campos são opcionais (`Optional`) ou têm valor default (`false`). SwiftData com `SwiftData.Schema` automático (default) deve adicionar as colunas sem necessidade de migration explícita, pois:
- `String?` → nova coluna NULLable
- `Bool = false` → nova coluna com default

Isso é seguro para lightweight migration automática do Core Data.

- [ ] **Step 3: Compilar e verificar**

```bash
xcodegen generate
```

Build scheme `WawaNoteCore` e `wawa-note`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add importSourceApp, isIncomplete, importError to KnowledgeItem

- importSourceApp: Bundle ID of the app that shared the content
- isIncomplete: true if extension timed out during import
- importError: error message for partial/failed imports

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Atualizar app principal — discoverImportedItems e remover scan antigo

**Files:**
- Modify: `wawa-note/UI/Home/HomeView.swift:120-135` (substituir `scanSharedDirectoryAndImport`)
- Modify: `wawa-note/UI/Home/HomeView.swift:384,407-408` (remover chamadas antigas)
- Modify: `wawa-note/Resources/Info.plist` (remover URL scheme `wawanote` se não for usado para mais nada)

**Interfaces:**
- Consumes: Tasks 1-7 (framework completo + extensão reescrita)
- Produces: `HomeViewModel.discoverImportedItems()` — query SwiftData por itens importados

- [ ] **Step 1: Substituir scanSharedDirectoryAndImport por discoverImportedItems**

No arquivo `wawa-note/UI/Home/HomeView.swift`, substituir o método `scanSharedDirectoryAndImport()` (linhas 120-135):

```swift
func discoverImportedItems() async {
    guard let ctx = modelContext, let queue = processingQueue else { return }

    let draftPredicate = #Predicate<KnowledgeItem> {
        $0.isImported == true && $0.statusRaw == ItemStatus.draft.rawValue
    }
    let descriptor = FetchDescriptor<KnowledgeItem>(predicate: draftPredicate)

    guard let items = try? ctx.fetch(descriptor), !items.isEmpty else { return }

    logger.info("Discovered \(items.count) imported items to process")

    for item in items {
        // Mark as queued to prevent double-enqueue
        item.statusRaw = ItemStatus.queuedForTranscription.rawValue

        // Handle incomplete items
        if item.isIncomplete {
            logger.warning("Item \(item.id) was incomplete — will re-extract metadata")
            // The pipeline will handle missing metadata
        }

        queue.enqueue(item.id)
    }

    try? ctx.save()
}
```

Adicionar o import do Logger no topo se não existir:
```swift
import OSLog
private let logger = Logger(subsystem: "com.wawa-note", category: "home-view")
```

Remover TODO o método `scanSharedDirectoryAndImport()` (linhas 120-135).

- [ ] **Step 2: Atualizar chamadas no HomeView**

Localizar a chamada em `onAppear` ou `.task` (linha ~384):
```swift
// ANTES:
await importVM.scanSharedDirectoryAndImport()

// DEPOIS:
await importVM.discoverImportedItems()
```

Remover o handler `onOpenURL` (linhas 407-408):
```swift
// REMOVER estas linhas:
.onOpenURL {
    if $0.scheme == "wawanote" { Task { await importVM.scanSharedDirectoryAndImport() } }
}
```

- [ ] **Step 3: Adicionar discoverImportedItems no onAppear da HomeView**

Localizar o `.task` ou `.onAppear` do `HomeView` e garantir que chame `discoverImportedItems()`:

```swift
.task {
    await importVM.discoverImportedItems()
}
```

Também adicionar listener para quando o app volta ao foreground. No `HomeView`, adicionar:

```swift
.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
    Task {
        await importVM.discoverImportedItems()
    }
}
```

- [ ] **Step 4: Remover URL scheme wawanote:// do Info.plist (opcional)**

Se o URL scheme `wawanote` não for usado para mais nada além do `wawanote://import`, removê-lo do `wawa-note/Resources/Info.plist`:

```xml
<!-- REMOVER este bloco se existir: -->
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>wawanote</string>
        </array>
    </dict>
</array>
```

Verificar antes se há outros usos do scheme `wawanote://`:

```bash
grep -rn "wawanote://" wawa-note/ --include="*.swift"
```

- [ ] **Step 5: Gerar projeto e compilar**

```bash
xcodegen generate
```

Build scheme `wawa-note` (⌘B).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: replace scanSharedDirectoryAndImport with discoverImportedItems

- Query SwiftData for isImported + status draft instead of file polling
- Removed onOpenURL handler for wawanote:// scheme
- Added willEnterForeground listener for timely item discovery
- Items marked as queued to prevent double-enqueue

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Build final e smoke test

**Files:**
- Nenhum arquivo novo/modificado (só verificação)

**Interfaces:**
- Consumes: Tasks 1-8 (sistema completo)

- [ ] **Step 1: Gerar projeto limpo**

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios
xcodegen generate
```

- [ ] **Step 2: Build todos os targets**

```bash
# Build framework
xcodebuild -project wawa-note.xcodeproj -scheme WawaNoteCore -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20

# Build share extension
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note-share -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20

# Build main app
xcodebuild -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```

Todos devem terminar com `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Rodar testes unitários existentes**

```bash
xcodebuild test -project wawa-note.xcodeproj -scheme wawa-note -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -40
```

Todos os testes existentes devem passar. Se algum falhar devido à movimentação de arquivos, corrigir imports ou paths.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: final build verification — all targets compile, tests pass

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Deploy no dispositivo físico e validação manual

**Files:**
- Nenhum (testes manuais no iPhone 14 Plus)

**Interfaces:**
- Consumes: Task 9 (build limpo)

- [ ] **Step 1: Build e instalar no iPhone 14 Plus**

```bash
cd /Users/wagnermontes/Documents/GitHub/wawa-note-ios
make deploy DEVICE=14plus
```

- [ ] **Step 2: Testar share de áudio (WhatsApp → Wawa Note)**

1. Abrir WhatsApp no iPhone
2. Selecionar um áudio recebido
3. Clicar em Share (Compartilhar)
4. Selecionar "Wawa Note" na lista de apps
5. **Esperado:** Extensão abre, mostra "Importing...", depois "✓ Imported!"
6. Abrir Wawa Note → áudio aparece no Inbox com status "draft"
7. Aguardar pipeline processar (transcrição + análise)

- [ ] **Step 3: Testar share de imagem (Fotos → Wawa Note)**

1. Abrir Fotos
2. Selecionar 1-3 imagens
3. Share → Wawa Note
4. **Esperado:** Extensão mostra progresso "1/3", "2/3", "3/3", depois "✓ Imported!"
5. Abrir Wawa Note → imagens aparecem no Inbox

- [ ] **Step 4: Testar share de URL (Safari → Wawa Note)**

1. Abrir Safari
2. Navegar para qualquer site
3. Share → Wawa Note
4. **Esperado:** Extensão processa e confirma
5. Abrir Wawa Note → webBookmark aparece com URL

- [ ] **Step 5: Testar share de texto (Notes → Wawa Note)**

1. Abrir Notes
2. Selecionar texto em uma nota
3. Share → Wawa Note
4. **Esperado:** Extensão processa e confirma
5. Abrir Wawa Note → nota de texto aparece

- [ ] **Step 6: Testar share de documento (Files → Wawa Note)**

1. Abrir Files
2. Selecionar PDF, Markdown, ou JSON
3. Share → Wawa Note
4. **Esperado:** Extensão detecta formato e importa
5. Abrir Wawa Note → documento aparece

- [ ] **Step 7: Testar edge case — cancelamento**

1. Iniciar share de qualquer conteúdo
2. Tocar "Cancel" na extensão
3. **Esperado:** Extensão fecha, nenhum item criado no banco

---

## Verification Checklist

Antes de considerar o trabalho completo, verificar:

- [ ] `WawaNoteCore.framework` compila com `REQUIRE_ONLY_APP_EXTENSION_SAFE_API = YES`
- [ ] `wawa-note-share` compila e linka WawaNoteCore
- [ ] `wawa-note` compila com `import WawaNoteCore` em todos os arquivos necessários
- [ ] Testes unitários existentes passam (27 testes em `CoreServicesTests`)
- [ ] Extensão NÃO contém código que abre o app principal
- [ ] Extensão NÃO referencia APIs bloqueadas (EKEventStore, CoreSpotlight, etc.)
- [ ] Share Extension aparece no share sheet para áudio, imagem, URL, texto, documentos
- [ ] Importação via extensão cria KnowledgeItem visível no app principal
- [ ] Pipeline processa itens importados corretamente
- [ ] `wawanote://import` URL scheme removido ou inofensivo
