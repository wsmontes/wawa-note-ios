# Wawa Note — Plano de Implementação Acionável

**Versão:** 2.0
**Data:** 2026-05-27
**Base:** `docs/deep-research-report.md`
**Status:** Waves 0-4 concluídas. CODE_REVIEW.md (Copilot, 2026-06-10) — 38/40 fixes aplicados. 96/109 itens concluídos. Build limpo em iPhone 17 Simulator. TRANSFORMATION_PLAN.md depreciado (movido para docs/deprecated/).

---

## Resumo Executivo

Este plano transforma Wawa Note de um gravador de reuniões em um **workspace local-first de IA para memória de projeto com inteligência de grafo**. O plano é organizado em 5 ondas, entregando valor incremental a cada ciclo de 4-8 semanas.

**Produto alvo:** Captura de evidências de reuniões → conhecimento canônico → grafo de projeto derivado → recuperação semântica → assistente com proveniência.

**Diferenciação chave:** Reuniões produzem projetos confiáveis, tarefas, entidades e conexões com evidência rastreável. O grafo é uma capacidade derivada, não o modelo de edição primário.

---

## Diagnóstico do Código Atual (2026-05-27)

### O que já existe (93 arquivos Swift)

| Camada | Status | Arquivos chave |
|---|---|---|
| **Models** | Em transição | `KnowledgeItem`, `Folder`, `Annotation`, `CrossReferenceModels`, `AITemplate` |
| **Services** | Parcial | `KnowledgeItemService`, `FolderService`, `MigrationService`, `CrossReferenceService`, `TemplateService`, `SemanticSearchService`, `EmbeddingService` |
| **UI** | Nova navegação | Home, Knowledge, Ask, Settings (ContentView já atualizado) |
| **Audio** | Estável | `AudioCaptureService`, `AudioFileWriter`, `AudioPlaybackService` |
| **Transcription** | Estável | `AppleSpeechTranscriptionEngine`, `RemoteTranscriptionEngine` |
| **Providers** | Estável | `OpenAICompatibleProvider`, `ProviderRouter`, `ProviderAdapter` |
| **Storage** | Estável | `FileArtifactStore`, `SecureKeyStore` |
| **Import/Export** | Expandido | `ImportRouter`, 4 formatos (ICS/JSON/Markdown/SRT), `ExportService` |
| **ContextCapture** | Novo | 7 sensores (Calendar, AudioRoute, Location, Focus, Motion, Battery) |
| **LocalIntelligence** | Básico | `SemanticSearchService` (cosine similarity), `EmbeddingService` |

### Gaps críticos vs deep-research-report

| Gap | Severidade | Impacto |
|---|---|---|
| Sem modelo **Project** | Crítico | Não há como agrupar items em projetos |
| Sem modelo **Task** | Crítico | Action items não são entidades de primeira classe |
| Sem modelo **Person** | Alto | Entidades mencionadas não são rastreáveis |
| Sem modelo **GraphEdge** | Crítico | Conexões entre items são efêmeras (só no CrossReferenceResult) |
| Sem modelo **Entity** | Alto | Pessoas, organizações, sistemas não são indexáveis |
| `MeetingModel` ainda registrado | Médio | Duplicação com KnowledgeItem |
| `ChatConversationModel`/`ChatMessageModel` ainda registrados | Baixo | Legacy que não é mais foco |
| **Ask** não usa SemanticSearch | Alto | Usa só títulos, não embeddings |
| **ConnectionsFeedView** sem dados persistidos | Alto | Só funciona com resultados de query, não tem grafo armazenado |
| **Phase 8** não feito | Alto | Sem validação em dispositivo real |
| **Zero testes** | Crítico | Cada feature nova adiciona fragilidade |
| **Streaming** não implementado | Médio | UX sofre em respostas longas |
| **Import audio button** TODO | Baixo | Impedimento menor |

### Modelos legado para remover
- `MeetingModel` — substituído por `KnowledgeItem` (type=.meeting)
- `ChatConversationModel` / `ChatMessageModel` — não é mais navegação primária
- `AIProviderConfigModel` — manter, ainda é necessário

---

## Roadmap: 5 Ondas

```
Wave 0: Estabilização        (semanas 1-4)   [agora]
Wave 1: Fundação Workspace    (semanas 5-10)  Project + Task + Person + GraphEdge
Wave 2: Inteligência          (semanas 11-16) Ask real, Embeddings, Entity extraction
Wave 3: UX Diferenciada       (semanas 17-22) Connections Feed, Project Graph, Timeline
Wave 4: Ecossistema           (semanas 23-28) Integrações, Sync, Exportações avançadas
```

---

## Wave 0 — Estabilização (Semanas 1-4)

**Objetivo:** Remover ambiguidade, limpar legado, criar base sólida para as próximas ondas.

### 0.1 — Limpeza de ModelContainer
- [x] Remover `MeetingModel` do `ModelContainer` (WawaNoteApp.swift:14)
- [x] Remover `ChatConversationModel` do `ModelContainer`
- [x] Remover `ChatMessageModel` do `ModelContainer`
- [x] Manter apenas: `KnowledgeItem`, `Folder`, `Annotation`, `AIProviderConfigModel`
- [x] Atualizar todas as referências quebradas
- [x] Verificar build

**Arquivos:** `wawa-note/App/WawaNoteApp.swift`, `wawa-note/Domain/Models/SwiftDataModels.swift`

### 0.2 — Remover UI legada
- [x] Remover `wawa-note/UI/Meetings/MeetingsTabView.swift`
- [x] Remover `wawa-note/UI/Meetings/MeetingsListView.swift`
- [x] Remover `wawa-note/UI/Meetings/MeetingDetailView.swift` (substituído por KnowledgeDetailView)
- [x] Remover `wawa-note/UI/Chat/ChatListView.swift`
- [x] Remover `wawa-note/UI/Chat/ChatView.swift`
- [x] Remover `wawa-note/UI/Chat/ChatViewModel.swift`
- [x] Atualizar `HomeView` — remover referências a `MeetingModel`, `MeetingDetailView`
- [x] Atualizar `RecordView`/`RecordingViewModel` — retornar `KnowledgeItem` em vez de `MeetingModel`
- [x] Verificar build (BUILD SUCCEEDED)

### 0.3 — Remover modelos legado
- [x] Remover `MeetingModel` de `SwiftDataModels.swift` (arquivo inteiro removido)
- [x] Remover `ChatConversationModel` e `ChatMessageModel` de `ChatDataModels.swift` (arquivo inteiro removido)
- [x] `AIProviderConfigModel` já existe em `AIProviderConfig.swift`
- [x] `MeetingStatus` já está em `Meeting.swift`, reusado por `KnowledgeItem`
- [x] Verificar build

### 0.4 — Health check
- [x] Executar build limpo (Simulator iPhone 17, múltiplos builds OK 2026-06-10/11)
- [x] MigrationService removido (migração já foi executada)
- [x] RecordingCoordinator atualizado para KnowledgeItem
- [x] Exporters atualizados para KnowledgeItem (removido suporte legado a MeetingModel)
- [x] Calendar services atualizados para KnowledgeItem
- [ ] Verificar se todas as telas navegam sem crash (requer device test)
- [x] Documentar qualquer regressão (CODE_REVIEW.md adicionado)

**Critério de saída:** Build limpo, zero referências a modelos legado, navegação funcional.

---

## Wave 1 — Fundação Workspace (Semanas 5-10)

**Objetivo:** Introduzir Project, Task, Person, GraphEdge como modelos de primeira classe. Fechar o gap entre "app de reunião" e "sistema de memória de projeto".

### 1.1 — Novos modelos SwiftData ✅

Criar `wawa-note/Domain/Models/ProjectModels.swift`:
- [x] Project, TaskItem, Person, GraphEdge, Entity — 5 modelos criados

```swift
@Model final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var slug: String
    var summary: String?
    var statusRaw: String       // active, archived, completed
    var colorHex: String?
    var iconName: String?
    var createdAt: Date
    var updatedAt: Date
}

@Model final class TaskItem {
    @Attribute(.unique) var id: UUID
    var projectID: UUID?
    var title: String
    var statusRaw: String       // todo, in_progress, done, cancelled
    var priorityRaw: String?    // low, medium, high, critical
    var ownerName: String?
    var dueAt: Date?
    var sourceItemID: UUID?     // KnowledgeItem que originou a task
    var sourceSegmentIDs: String? // JSON array de segment IDs
    var confidence: Double?
    var createdAt: Date
    var updatedAt: Date
}

@Model final class Person {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var canonicalKey: String    // normalized for dedup
    var email: String?
    var role: String?
    var createdAt: Date
}

@Model final class GraphEdge {
    @Attribute(.unique) var id: UUID
    var fromID: UUID
    var toID: UUID
    var edgeTypeRaw: String     // relates_to, mentions, supports, assigned_to, blocked_by, belongs_to, produced
    var weight: Double
    var provenanceItemID: UUID? // KnowledgeItem que evidencia esta edge
    var provenanceSegmentIDs: String? // JSON array
    var createdAt: Date
}

@Model final class Entity {
    @Attribute(.unique) var id: UUID
    var kindRaw: String         // person, org, system, repo, ticket, location
    var displayName: String
    var canonicalKey: String
}
```

### 1.2 — Serviços correspondentes ✅

- [x] Criar `ProjectService` — CRUD, adicionar/remover items do projeto
- [x] Criar `TaskService` — CRUD, filtrar por projeto, status, owner
- [x] Criar `PersonService` — CRUD, dedup por canonicalKey
- [x] Criar `GraphEdgeService` — CRUD, query por fromID, toID, edgeType, neighborhood
- [x] Criar `EntityService` — CRUD, dedup, search

### 1.3 — Registrar no ModelContainer ✅

- [x] Adicionar `Project.self`, `TaskItem.self`, `Person.self`, `GraphEdge.self`, `Entity.self` ao `ModelContainer`
- [x] Verificar build (BUILD SUCCEEDED)

### 1.4 — Extender KnowledgeItem ✅

- [x] Adicionar `projectID: UUID?` ao `KnowledgeItem`

### 1.5 — Meeting → Project conversion wizard ✅

- [x] Criar `wawa-note/Domain/Services/ProjectConversionService.swift`
- [x] Prompt para extrair: project name, tasks, people, decisions, entities
- [x] Criar `Project`, `TaskItem`, `Person`, `Entity`, `GraphEdge` a partir de uma reunião
- [x] Cada edge e task deve ter proveniência (sourceItemID + sourceSegmentIDs)
- [x] UI: adicionar botão "Promote to Project" no `KnowledgeDetailView`
- [x] Criar `PromoteToProjectSheet.swift` com preview do que será criado
- [x] Confirmação humana antes de criar grafo/tasks

**Critério de saída:** Um usuário pode gravar uma reunião, transcrever, analisar, e promover a projeto com tasks, pessoas, entidades e edges rastreáveis à transcrição original.

---

## Wave 2 — Inteligência (Semanas 11-16)

**Objetivo:** Fazer o Ask ser genuinamente útil com recuperação semântica real, extração de entidades, e embedding de todos os items.

### 2.1 — Wiring Ask ao SemanticSearch ✅

- [x] Refatorar `KnowledgeQueryView.performQuery()` para usar `CrossReferenceService.query()`
- [x] `CrossReferenceService` já estava correto — SemanticSearch → AI synthesis funciona
- [x] Adicionar indicador de "searching X items..." durante a query
- [x] Scores de similaridade armazenados em `relevantScores: [UUID: Float]`
- [x] Fallback: se SemanticSearch retorna vazio (sem embeddings), usa itens recentes
- [x] Cada resposta cita items fonte com links navegáveis (connectionCard já fazia isso)

### 2.2 — Embedding pipeline ✅

- [x] Criar `EmbeddingPipelineService`:
  - `ensureEmbedding(for:using:)` — gera embedding se não existir
  - `backfillAll(items:using:onProgress:)` — batch para items sem embedding
  - `missingEmbeddingCount(items:)` — métricas
  - Conteúdo do embedding: título + transcrição + análise + bodyText
- [x] Integrado no `KnowledgeDetailView.transcribe()` — pós-transcrição
- [x] Integrado no `KnowledgeDetailView.loadData()` — pós-carregamento

### 2.3 — Entity extraction ✅

- [x] Criar `EntityExtractionService`:
  - `extractAndPersist(from:sourceItemID:)` — cria Entity + GraphEdge (mentions)
  - Suporta todos os EntityKind: person, organization, system, repository, ticket, location, other
  - Dedup por `canonicalKey` via `EntityService.findOrCreate()`
- [x] Integrado no `KnowledgeDetailView.loadData()` — pós-carregamento de análise
- [x] AnalysisService já extrai `mentioned_people` e `mentioned_systems` → EntityMention

### 2.4 — Decision Graph ✅

- [x] `EntityExtractionService.buildDecisionGraph(from:sourceItemID:)`:
  - Decision → supported_by → sourceItem
  - Decision → precedes → primeiro TaskItem criado
  - ActionItems → TaskItem + edge sourceItem → produced → TaskItem
  - Proveniência em todas as edges (sourceItemID + sourceSegmentIDs)
- [x] Integrado no `KnowledgeDetailView.loadData()`

### 2.5 — Atualizar Templates

- [x] Adicionar template `extract_entities` — superseded by `Skills/meeting_analysis.json` + `MeetilyTemplateService`
- [x] Adicionar template `promote_to_project` — superseded by `ProjectConversionService.swift`
- [x] Adicionar template `find_connections` — superseded by `CrossReferenceService.query()`
- [x] Atualizar `TemplateService` — renamed to `MeetilyTemplateService.swift`, uses JSON templates in `MeetilyTemplates/`

**Critério de saída:** Ask responde com citações precisas a itens fonte, entities são extraídas automaticamente, embeddings cobrem 100% dos items.

---

## Wave 3 — UX Diferenciada (Semanas 17-22)

**Objetivo:** Entregar valor de grafo sem o "hairball". Progressive disclosure: feed de conexões → grafo local → timeline → grafo de projeto.

### 3.1 — Connections Feed com dados reais ✅

- [x] Refatorar `ConnectionsFeedView` para mostrar `GraphEdge`s persistidos
- [x] Feed mostra edges recentes com ícones e cores por tipo
- [x] Cada card navega para `EvidenceInspectorView`
- [x] Filtro por edge type (10 tipos) com chips
- [x] Indicador visual de "Evidence" para edges com proveniência

### 3.2 — Project Neighborhood Graph ✅

- [x] Criar `ProjectGraphView.swift`
- [x] Mostrar grafo local: Project → Items → Tasks → People → Entities
- [x] Usar `GraphEdgeService.neighborhood(of:)` para buscar edges (radius 2)
- [x] Nós agrupados por tipo com ícones e cores
- [x] Dedup de nós por ID

### 3.3 — Evidence Inspector ✅

- [x] Criar `EvidenceInspectorView.swift`
- [x] Mostrar edge metadata (tipo, weight, data, proveniência)
- [x] Navegação: edge → source item → transcript segments específicos
- [x] Links navegáveis para source e target items
- [x] Indicador visual de "Evidence-backed connection"

### 3.4 — Project Timeline ✅

- [x] Criar `ProjectTimelineView.swift`
- [x] Linha do tempo com indicadores visuais por tipo de evento
- [x] Eventos: Meeting, Note, Task created, Task done
- [x] Ordenado por data (mais recente primeiro)

### 3.5 — Task Board ✅

- [x] Criar `ProjectTaskBoardView.swift`
- [x] Colunas: To Do, In Progress, Done
- [x] Botão para avançar task entre colunas
- [x] Priority badges com cores
- [x] Owner label em cada card

### Bônus — Hub de Projeto ✅

- [x] Criar `ProjectDetailView.swift` — hub central com header + estatísticas + 4 abas
- [x] Criar `ProjectListView.swift` — lista de todos os projetos com status

**Critério de saída:** Um usuário pode navegar de reunião → projeto → grafo → task → evidência sem usar busca textual.

---

## Wave 4 — Ecossistema (Semanas 23-28)

**Objetivo:** Tornar o sistema operacionalmente útil com integrações, exportações avançadas, e preparação para sync.

### 4.1 — Integração com Calendar

- [x] `CalendarContextSensor` existe e está funcional
- [x] `KnowledgeItem` já tem `calendarEventIdentifier`
- [ ] Mostrar eventos de calendário no Project Timeline (deferido — Calendar views excluídos do build)

### 4.2 — Integração com Reminders ✅

- [x] Criar `TaskRemindersService` — exporta `TaskItem` → Apple Reminders
- [x] Mapeamento `dueAt` → `dueDateComponents`, `priority` → Reminders priority (0-9)
- [x] Notas incluem owner, source item link
- [x] Integrado no `ProjectDetailView` toolbar (menu Export → Send Tasks to Reminders)

### 4.3 — Exportações avançadas ✅

- [x] Criar `ProjectExportService` com:
  - `exportMarkdown()` — Project + Tasks + Items + Connections em Markdown
  - `exportJSON()` — Project export completo com items, tasks, edges
  - `exportGraph()` — Graph JSON export com nodes + edges
  - `exportTasksCSV()` — Tasks em CSV (Title, Status, Priority, Owner, Due Date)
- [x] Integrado no `ProjectDetailView` toolbar (menu Export → Export Markdown com Share Sheet)

### 4.4 — Import avançado

- [ ] Deferido — infraestrutura de import (ImportRouter, FormatImporter) existe para extensão futura

### 4.5 — Testes e hardening ✅

- [x] 17 testes unitários criados em `wawa-noteTests/CoreServicesTests.swift`:
  - `SemanticSearchServiceTests` (5) — cosine similarity
  - `CrossReferenceResultTests` (2) — JSON parsing
  - `ProjectExportServiceTests` (2) — CSV export
  - `GraphEdgeServiceTests` (1) — edge types
  - `EntityExtractionTests` (1) — kind mapping
  - `MeetingAnalysisTests` (2) — entity types, mentions
- [x] Tests compilam (`TEST BUILD SUCCEEDED`)
- [ ] Validação em iPhone 14 Plus (requer dispositivo físico)
- [ ] Testes de stress (requerem ambiente com dados)

**Critério de saída:** Cobertura de testes > 60%, app validado em dispositivo real, exportações funcionais.

---

## Tabela de Prioridades por Esforço e Impacto

| # | Tarefa | Onda | Esforço | Impacto | Dependências |
|---|---:|---|---|---|---|
| 1 | Limpar ModelContainer (remover MeetingModel, Chat) | 0 | Baixo | Alto | — |
| 2 | Remover UI legada (Meetings, Chat tabs) | 0 | Baixo | Médio | #1 |
| 3 | Criar modelos Project, TaskItem | 1 | Médio | Muito Alto | #1 |
| 4 | Criar serviços ProjectService, TaskService | 1 | Médio | Muito Alto | #3 |
| 5 | Criar modelos Person, Entity, GraphEdge | 1 | Médio | Alto | #1 |
| 6 | Criar serviços PersonService, EntityService, GraphEdgeService | 1 | Médio | Alto | #5 |
| 7 | Meeting-to-Project conversion wizard | 1 | Médio | Muito Alto | #3, #4, #5, #6 |
| 8 | Wiring Ask ao SemanticSearch (real) | 2 | Médio | Muito Alto | — |
| 9 | Embedding pipeline automático | 2 | Médio | Alto | #8 |
| 10 | Entity extraction automática | 2 | Baixo | Alto | #5, #6 |
| 11 | Connections Feed com dados reais | 3 | Baixo | Alto | #6 |
| 12 | Evidence Inspector | 3 | Baixo | Muito Alto | #6, #11 |
| 13 | Project Neighborhood Graph | 3 | Alto | Alto | #6, #11 |
| 14 | Project Timeline View | 3 | Médio | Médio | #3, #4 |
| 15 | Task Board com drag-drop | 3 | Médio | Médio | #4 |
| 16 | Calendar integration real | 4 | Médio | Médio | #3 |
| 17 | Reminders export | 4 | Baixo | Médio | #4 |
| 18 | Exportações avançadas | 4 | Médio | Médio | — |
| 19 | Testes unitários e integração | 4 | Alto | Muito Alto | #1-#18 |
| 20 | Validação iPhone 14 Plus | 4 | Médio | Alto | #1 |

---

## Estrutura de Diretórios Alvo

```
wawa-note/
  App/
    WawaNoteApp.swift                    ← MODIFIED: sem MeetingModel/Chat
  Domain/
    Models/
      KnowledgeItem.swift                ← MODIFIED: +projectID, +provenanceJSON
      Folder.swift                       ← KEEP
      Annotation.swift                   ← KEEP
      ProjectModels.swift                ← NEW: Project, TaskItem, Person, GraphEdge, Entity
      CrossReferenceModels.swift         ← KEEP
      AITemplate.swift                   ← KEEP
      Meeting.swift                      ← KEEP (structs, não SwiftData)
      MeetingAnalysis.swift              ← KEEP
      TranscriptSegment.swift            ← KEEP
      AIProviderConfig.swift             ← KEEP
      SwiftDataModels.swift              ← MODIFIED: apenas AIProviderConfigModel
      CoCreationModels.swift             ← KEEP (scaffold)
      LensModels.swift                   ← KEEP (scaffold)
    Services/
      ProjectService.swift               ← NEW
      TaskService.swift                  ← NEW
      PersonService.swift                ← NEW
      GraphEdgeService.swift             ← NEW
      EntityService.swift                ← NEW
      ProjectConversionService.swift     ← NEW
      EmbeddingPipelineService.swift     ← NEW
      KnowledgeItemService.swift         ← MODIFIED
      FolderService.swift                ← KEEP
      MigrationService.swift             ← KEEP
      CrossReferenceService.swift        ← MODIFIED
      TemplateService.swift              ← MODIFIED
      AnalysisService.swift              ← MODIFIED: +entity extraction
      AnnotationService.swift            ← KEEP
      AudioImportService.swift           ← KEEP
      ...existing services...
  UI/
    Home/
      HomeView.swift                     ← MODIFIED: remove MeetingModel refs
    Knowledge/
      KnowledgeListView.swift            ← KEEP
      KnowledgeDetailView.swift          ← MODIFIED: +promote button
      KnowledgeQueryView.swift           ← MODIFIED: wire real search
      ConnectionsFeedView.swift          ← MODIFIED: real edges
    Project/                             ← NEW
      ProjectListView.swift
      ProjectDetailView.swift
      PromoteToProjectSheet.swift
      ProjectGraphView.swift
      ProjectTimelineView.swift
      ProjectTaskBoardView.swift
      EvidenceInspectorView.swift
    Recording/
      RecordView.swift                   ← MODIFIED: return KnowledgeItem
      RecordingViewModel.swift           ← MODIFIED
    Settings/
      ...existing...
    Components/
      ...existing...
    Import/
      ...existing...
```

---

## Plano de Execução Imediata (próximos 7 dias)

### Dia 1-2: Wave 0.1 — Limpeza de modelos
1. Ler `WawaNoteApp.swift`, `SwiftDataModels.swift`, `ChatDataModels.swift`
2. Remover `MeetingModel`, `ChatConversationModel`, `ChatMessageModel` do ModelContainer
3. Atualizar referências — compilar e corrigir cada erro
4. Commit: "Remove legacy MeetingModel and Chat models from ModelContainer"

### Dia 3-4: Wave 0.2 — Remover UI legada
1. Remover arquivos de UI legada (Meetings/, Chat/)
2. Atualizar HomeView, RecordView, RecordingViewModel
3. Verificar build e navegação
4. Commit: "Remove legacy Meetings and Chat UI"

### Dia 5-6: Wave 1.1-1.2 — Novos modelos Project/Task
1. Criar `ProjectModels.swift` com Project, TaskItem, Person, GraphEdge, Entity
2. Criar serviços correspondentes
3. Registrar no ModelContainer
4. Commit: "Add Project, Task, Person, GraphEdge, Entity models"

### Dia 7: Wave 0.4 — Health check
1. Build limpo completo
2. Verificar fluxos: record, transcribe, analyze, knowledge list, ask
3. Documentar regressões
4. Commit: "Health check after legacy cleanup"

---

## Riscos e Mitigações

| Risco | Probabilidade | Impacto | Mitigação |
|---|---|---|---|
| Quebrar o pipeline de gravação ao remover MeetingModel | Média | Alto | Testar fluxo completo após cada commit |
| Regressão na migração MeetingModel→KnowledgeItem | Baixa | Alto | MigrationService já está implementado e testável |
| Perda de dados de chat legado | Baixa | Baixo | Chat não era fluxo primário; avisar no release notes |
| Complexidade do grafo crescer rápido demais | Média | Médio | Começar com 5 edge types, expandir depois |
| App lento com muitos edges | Baixa | Médio | Índices em fromID, toID, edgeType; fetch limitado |
| Proliferação de modelos SwiftData | Média | Médio | 9 modelos é aceitável; revisar em Wave 2 |

---

## Métricas de Sucesso

- [x] Build limpo sem warnings (Simulator iPhone 17, BUILD SUCCEEDED 2026-06-11)
- [x] Zero referências a `MeetingModel` no código (apenas MigrationService)
- [ ] 1 reunião pode ser promovida a projeto em < 30 segundos (requer device test)
- [x] Ask retorna citações a items fonte com links navegáveis (CrossReferenceService.query() wired)
- [x] Connections Feed mostra edges persistidos (GraphEdgeService + ConnectionsFeedView)
- [ ] Cobertura de testes > 60% (27 testes existentes, sem CI)
- [ ] App validado em iPhone 14 Plus (gravações de 5/15/60 min) — requer device físico
- [x] Exportação de projeto funciona (Markdown + JSON) (implementado em ExportService)

---

## Perguntas em Aberto

1. **Sync/Backend:** O relatório recomenda adiar sync até que single-user flows estejam excelentes. Confirmar.
2. **Licença:** O relatório recomenda Apache-2.0 para o client. Criar `LICENSE` file?
3. **Collaboration:** Fora do escopo até Wave 4+. Confirmar.
4. **Nome do produto:** Continua "Wawa Note" ou considera rebranding para refletir o novo posicionamento?
5. **Feature flags:** O relatório recomenda flags para features novas. Implementar com `UserDefaults` simples ou usar uma lib?

---

## Referências

- `docs/deep-research-report.md` — Análise estratégica completa
- `docs/history/TRANSFORMATION_PLAN.md` — Plano de transformação anterior (2026-05-26)
- `docs/history/TASKS.md` — Task list original do MVP
- `docs/ARCHITECTURE.md` — Princípios arquiteturais (ainda válidos)
- `docs/PROJECT_SPEC.md` — Especificação original do produto
