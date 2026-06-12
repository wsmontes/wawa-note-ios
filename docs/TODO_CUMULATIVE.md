# TODO — Wawa Note

> Consolidado em 2026-06-12 a partir de auditoria de 47 perspectivas.
> Prioridade: P0 = crash/data loss, P1 = broken flow, P2 = friction, P3 = polish (omitido aqui).

---

## 🔴 P0 — Críticos (crash, perda de dados, segurança crítica)

### Audio & Recording

- [ ] **Crash: BUG IN CLIENT OF LIBDISPATCH ao iniciar gravação.** `MPNowPlayingInfoCenter` sendo chamado de thread não-main. `nowPlayingTimer` (`Timer.scheduledTimer`) pode estar sendo criado em background thread após `await captureService.startRecording()`. Reproduzível, root cause não confirmada.
- [ ] **Crash: SWIFT TASK CONTINUATION MISUSE em transcribeDirect.** `SFSpeechRecognizer.recognitionTask` entrega erro E resultado final no mesmo callback → `continuation.resume()` chamado 2x. Corrigido com flag `hasResumed`, mas cloud fallback tem o mesmo risco.
- [ ] **AAC M4A causa gaps de 40-90s no SFSpeechRecognizer.** `AudioFileWriter._openSegment()` escreve AAC M4A para sample rates >=16kHz. O `SFSpeechRecognizer` perde sincronização com o bitstream AAC. Solução parcial implementada (`prepareForRecognition` via `AVAudioConverter` → PCM WAV) mas ainda **não validada com sucesso**.

### Data Layer

- [ ] **Crash CoreData: `KnowledgeItem.tags: [String]`.** `"Could not materialize Objective-C class named 'Array' from declared attribute value type 'Array<String>'"`. SwiftData não suporta `[String]` como atributo direto — precisa de `@Attribute(.transformable)` ou relação separada.

### Security

- [ ] **Áudio e transcrições armazenados localmente sem criptografia.** `FileArtifactStore` usa `FileManager` direto — arquivos legíveis por qualquer processo com acesso ao container do app.
- [ ] **SecureKeyStore accessibility.** Se configurado como `kSecAttrAccessibleWhenUnlocked`, keys não disponíveis em background. Deveria ser `kSecAttrAccessibleAfterFirstUnlock` para permitir pipeline em background.

---

## 🟠 P1 — Alta prioridade (fluxo quebrado, UX comprometida)

### Audio & Recording Pipeline

- [ ] **`RecordingCoordinator` — 765 linhas, 8 responsabilidades.** Orquestra captura, NowPlaying, pipeline, manifest, crash recovery, contexto. Split em: `RecordingSessionService`, `ManifestService`, `CrashRecoveryService`, `NowPlayingService`.
- [ ] **`AudioCaptureService` — 1551 linhas.** Máquina de estado + captura + recovery + escrita + checkpoints. Extrair `AudioRouteManager`.
- [ ] **`prepareForRecognition` frágil — 3 versões em 1 dia.** Passou por `AVAudioConverter` → `AVAssetReader+CMBlockBuffer` → `AVAudioConverter`. Precisa de teste unitário.
- [ ] **`AudioChunker` produz AAC M4A → `prepareForRecognition` decodifica de volta.** Round-trip inútil. Chunker deveria produzir PCM WAV direto, eliminando `prepareForRecognition`.
- [ ] **Pipeline disparado diretamente em `stopRecording()` — não passa pelo `ProcessingQueue`.** Se o pipeline falha, não tem retry automático. Só `reprocessItem()` manual da UI tenta de novo.
- [ ] **Sem timeout ou cancelamento do pipeline.** Se o agente entra em loop ou a API fica pendurada, o item fica preso até o app ser morto.
- [ ] **`RecordingCoordinator.startRecording()` cria `KnowledgeItem` antes de saber se o microfone funciona.** Se `captureService.startRecording()` falha, item é rollback — mas usuário vê o item piscar na UI.
- [ ] **`cleanupOrphanedRecordings()` marca itens como `.recorded`/`.failed` mas NÃO dispara pipeline.** Itens recuperados de crash ficam sem transcrição/análise.
- [ ] **Sem feedback visual durante transcrição.** `isTranscribing` nunca era setado para `true`. Parcialmente corrigido, mas `isPipelineProcessing` depende de notificação que pode chegar antes do `.onAppear`.
- [ ] **3 caminhos de transcrição sem tracing centralizado.** `transcribeSegmented`, `transcribeSingleFile`, `transcribeFile` (chunked) — cada um com logging e error handling diferente. Sem visibilidade de qual caminho foi usado, com qual formato, ou quanto tempo levou.
- [ ] **`ContentPipelineService` bloqueia MainActor.** `process()` é `@MainActor` — bloqueia UI durante chunking e transcrição.

### Agent System & Chat

- [ ] **AgentLoop sem visibilidade de tool calls no chat.** Usuário vê o texto final mas não sabe quais tools foram chamadas, com quais argumentos, ou o resultado.
- [ ] **Sem streaming de pensamento (thinking) do modelo.** `thinkingActive` existe mas não é exposto na UI do chat.
- [ ] **AgentLoop sem circuit breaker.** Se o agente falha 5x no mesmo tool call, continua tentando até `maxIterations: 15`.
- [ ] **AgentLoop sem salvamento intermediário.** Se crasha na iteração 14 de 15, todo o progresso é perdido.
- [ ] **`WriteAnalysisTool` sem rollback se validação falha.** JSON parcial pode ser persistido.
- [ ] **System prompts hardcoded em cada serviço.** `ContentPipelineService`, `ContentExtractionService`, `ChatViewModel` — cada um com seu próprio prompt, sem revisão centralizada e versionamento.
- [ ] **`AIConfigService.requestParams()` detecta reasoning models por nome hardcoded.** Novos modelos (Claude Opus 4.8, GPT-5) não serão detectados até atualizar código.
- [ ] **Sem tracking de custos de API.** Usuário não sabe quanto gastou em tokens. Sem budget ou alerta de consumo.

### Data Layer & Models

- [ ] **`ItemStatus` enum com 10 casos sem documentação de máquina de estados.** Transições válidas não documentadas. `cleanupOrphanedRecordings` e `ContentPipelineService` fazem transições sem validar se são legais.
- [ ] **`KnowledgeItem.status` atualizado em múltiplos lugares sem coordenação.** `RecordingCoordinator`, `ContentExtractionService`, `ContentPipelineService`, `KnowledgeDetailView.reprocessItem()` todos escrevem `item.status` diretamente.
- [ ] **`KnowledgeItemService` com responsabilidades sobrepostas.** `ContentPipelineService`, `ContentExtractionService`, `ProjectService`, `TaskService` todos fazem fetch e update de `KnowledgeItem` diretamente — sem single source of truth.

### Project Intelligence

- [ ] **`CrossReferenceResult` DTO não persiste.** Connection, Insight, Contradiction são efêmeros — inteligência descoberta pelo agente se perde entre sessões.
- [ ] **Provenance (`sourceItemID` + `sourceSegmentIDs`) não validada na criação de GraphEdge.** Edges podem ser criados sem proveniência — viola requirement arquitetural.
- [ ] **`TaskBoardView` é uma lista, não um Kanban.** Sem drag-and-drop, sem swimlanes, sem WIP limits.
- [ ] **5 frameworks built-in (Meeting, Research, Planning, Learning, Custom) sem validação de schema.** Se o agente escreve JSON fora do schema, `FrameworkService.validateAnalysis()` rejeita silenciosamente.
- [ ] **`ProjectIngestionPipeline` sem deduplicação.** Se o mesmo item é analisado 2x, tasks/edges são duplicados.

### UI/UX

- [ ] **`KnowledgeDetailView` — 1800+ linhas.** View + lógica de negócio + transcrição + análise + badges. Extrair `KnowledgeDetailViewModel`.
- [ ] **Chat não mostra provider/modelo ativo.** Usuário não sabe se está falando com OpenAI, Anthropic, ou Gemini.
- [ ] **Sem indicador claro de "agent is working".** Só indicador de typing. Para tool calls longas, parece que travou.
- [ ] **Chat não tem acesso ao pipeline de análise e vice-versa.** Sistemas separados — chat não pode disparar análise, pipeline não pode pedir ajuda ao chat.
- [ ] **`ChatViewModel` duplica `SFSpeechRecognizer` com seu próprio `recognizeFile()`.** Transcrição no chat tem timeout de 10s, ignora erros — diferente do pipeline principal.
- [ ] **Sem onboarding flow.** App abre direto na tab Capture sem explicar o que faz ou sugerir próximos passos.

### Architecture & DI

- [ ] **Dependency injection inconsistente.** `RecordingCoordinator` recebe dependências por init. `ContentPipelineService` recebe `ModelContext` por init mas acessa `AIConfigService.shared` como singleton.
- [ ] **`AIConfigService.shared` — singleton global.** Impossível mockar em testes. Estado vaza entre testes.
- [ ] **`WawaNoteApp.swift` `init()` com 100+ linhas configurando serviços.** Deveria usar `ServiceContainer` ou `AppAssembly`.
- [ ] **Views SwiftUI grossas com lógica de negócio inline.** `KnowledgeDetailView` com `transcribe()`, `reprocessItem()`, `loadRawAnalysisJSON()` — tudo na View.
- [ ] **Error handling inconsistente.** `try?` usado em 80+ lugares — erros silenciosamente ignorados. `catch { }` vazio em 12+ lugares. Sem hierarquia de erros da aplicação.

### Privacy & Compliance

- [ ] **API keys em plaintext na memória.** `RemoteTranscriptionEngine` recebe `apiKey` como parâmetro — se um dump de memória for capturado, a key está exposta.
- [ ] **Transcripts e análises em JSON plaintext no disco.** Se o dispositivo for comprometido, todo o conteúdo das reuniões está legível.
- [ ] **Sem política de retenção de dados.** Áudios, transcrições e análises ficam no disco indefinidamente.
- [ ] **Sem `PrivacyInfo.xcprivacy` (Privacy Manifest).** Requerido pela Apple para apps que usam APIs de áudio, speech recognition, e rede.
- [ ] **Debug logs ativos em build de Release.** Logs de transcrição, pipeline, e provider expõem dados sensíveis.

### Testing

- [ ] **27 unit tests apenas em `CoreServicesTests.swift`.** Sem testes para: `AudioCaptureService`, `RecordingCoordinator`, `AppleSpeechTranscriptionEngine`, `ContentExtractionService`, `ContentPipelineService`, `AudioFileWriter`, `AudioChunker`, `NowPlayingController`.
- [ ] **Sem testes de integração para o pipeline completo.** Fluxo gravação → concatenação → transcrição → análise nunca foi testado automaticamente.
- [ ] **Sem mocks para `SFSpeechRecognizer`, `AVAudioEngine`, `MPNowPlayingInfoCenter`.** Testes dependem de hardware real.

---

## 🟡 P2 — Média prioridade (atrito, dívida técnica, qualidade)

### Audio & Recording

- [ ] **`AudioSessionManager` prioriza AirPlay > Bluetooth HFP > built-in.** Bluetooth HFP tem qualidade péssima (8kHz). Deveria ter opção de preferir built-in.
- [ ] **`AudioFileWriter` usa AAC para >=16kHz com bitrate adaptativo não documentado.** 24-96kbps dependendo do sample rate — sem evidência de que o SFSpeechRecognizer lida bem com todas as variantes.
- [ ] **`RecordingManifest` persiste no disco sem validação de integridade.** Crash no meio do write → JSON truncado → manifesto ilegível (retorna nil silenciosamente).
- [ ] **`AudioSegmentConcatenator` só loga `.completed` — falhas silenciosas.** `try?` em file copy, remove, export. Se a concatenação falha, o pipeline recebe `audio.m4a` incompleto.
- [ ] **`hasValidAudioData()` itera segmentos do manifesto checando arquivos no disco.** Se o manifesto está corrompido, áudio é considerado inválido mesmo existindo.
- [ ] **Crash recovery (`writeCheckpoint`) rejeita checkpoints >24h.** Se o usuário gravou ontem à noite e o app crashou, checkpoint é ignorado hoje de manhã.
- [ ] **`forceBuiltInMicRecovery()` — em caso de falha, estado fica `.failedFatal`.** Usuário perde a gravação inteira em vez de continuar com o que tinha.
- [ ] **Sem detecção de áudio silencioso.** Gravação de 10 minutos de silêncio produz arquivo válido mas transcrição vazia.
- [ ] **Sem pre-gravação buffer.** Útil para capturar "o que foi dito antes de apertar gravar".

### Agent System

- [ ] **`maxIterations: 15` fixo, sem adaptive loop.** Agentes simples consomem o mesmo limite que análises complexas.
- [ ] **Tools registradas estaticamente em `ContentPipelineService`.** `ShellTool()` e `WriteAnalysisTool()` são hardcoded. Novas tools exigem mudança de código.
- [ ] **Sem tool de busca semântica.** `SemanticSearchService` e `EmbeddingService` existem mas não estão expostos como tools do agente.
- [ ] **`ShellTool` executado sem sandbox.** Comandos shell do agente rodam com acesso total ao filesystem do app.
- [ ] **`ProviderRouter.resolveActive()` retorna nil se nenhum provider configurado — sem fallback ou sugestão.**
- [ ] **Sem cache de respostas do agente.** Mesmo item analisado 2x com mesmo prompt = 2 chamadas de API.
- [ ] **Sem validação de output do agente antes de persistir.** `WriteAnalysisTool` escreve JSON sem garantir schema válido.

### Data Layer

- [ ] **`@Model` sem `@Relationship` — usa `parentFolderID: UUID?`, `projectID: UUID?`.** Consistência depende de queries manuais. Sem integridade referencial garantida pelo SwiftData.
- [ ] **`Annotation` usa upsert pattern (delete + insert) sem operação atômica.** Se o app crasha entre delete e insert, perde anotações.
- [ ] **`ProjectService`, `TaskService`, `PersonService`, `GraphEdgeService` — 4 serviços com padrão idêntico mas sem protocolo comum.**
- [ ] **`@Query` em `InboxView` carrega TODOS os itens sem paginação.** Para 1000+ itens, a view fica lenta.
- [ ] **Sem `PrivacyInfo.xcprivacy` (Privacy Manifest).** Requerido pela Apple para apps que usam APIs sensíveis.
- [ ] **Sem versionamento de schema SwiftData explícito.** Depende de lightweight migration automática — frágil para mudanças complexas.

### UI/UX

- [ ] **Tags de status inconsistentes entre Inbox e Detail View.** Inbox usa capsule badges inline, Detail usa `AppStatusBadge` — duas implementações diferentes.
- [ ] **Inbox não mostra status de processamento em tempo real.** Itens sendo transcritos/analisados não têm indicador visual na lista.
- [ ] **4 tabs sem badges de atividade.** Nenhuma indicação de quantos itens precisam de review ou estão processando.
- [ ] **Settings enterrado — sem acesso rápido a provider/config.**
- [ ] **Tela de captura não mostra estado do microfone antes de gravar.** `No valid recording input` aparece só no log, não na UI.
- [ ] **`TranscriptGroup` vs segmentos crus — sem toggle.** Usuário pode querer timestamps precisos ou leitura fluida.
- [ ] **Tab "Explore" é project-first — usuário sem projetos vê tela vazia.** Sem onboarding ou sugestão de criar primeiro projeto.
- [ ] **Sem design system documentado.** Cores, fontes, espaçamentos definidos inline em cada View.
- [ ] **Strings em PT-BR hardcoded misturadas com EN.** `NowPlayingController` tem "Gravando"/"Pausado", outros lugares em inglês.
- [ ] **Sem `accessibilityLabel`/`accessibilityHint` nas views customizadas.** VoiceOver não descreve badges, botões de ação, ou estados.

### Import/Export

- [ ] **10 importers registrados sem validação de integridade do arquivo.** Se o arquivo está corrompido, o import falha silenciosamente.
- [ ] **Share Extension sem preview do conteúdo importado.** Usuário não vê o que está importando antes de confirmar.
- [ ] **Export sem preview.** Usuário não vê o formato antes de exportar (Markdown, JSON, SRT, etc.).
- [ ] **Calendar export (`CalendarSyncService`) cria EKEvent mas não atualiza.** Se o evento muda no app, o EKEvent não é sincronizado.
- [ ] **`RemindersExportService` não verifica duplicatas.** Exportar 2x cria reminders duplicados.

### Search & Discovery

- [ ] **Inbox search é local (filtra `allItems`) — sem busca full-text.** `SearchService` existe mas não é integrado ao campo de busca da Inbox.
- [ ] **`SemanticSearchService` implementado mas não wiring a nenhuma UI.**
- [ ] **`SpotlightIndexService` indexa itens mas não remove do índice quando deletados.** Spotlight mostra resultado fantasma.
- [ ] **`EmbeddingPipelineService.ensureEmbedding()` chamado após cada análise — mas embeddings nunca usados para busca.** Custo computacional sem benefício.

### Calendar & Reminders

- [ ] **`CalendarSyncService` lê eventos mas não lida com recorrência.** Eventos recorrentes aparecem uma vez só na timeline.
- [ ] **`CalendarSyncService` cria EKEvent sem verificar conflitos de horário.**
- [ ] **`CalendarEvent` model não tem `attendees`, `location`, ou `notes` da API do Calendar.** Dados do EKEvent são truncados.
- [ ] **`TaskRemindersService` exporta tasks mas não sincroniza bidirecionalmente.** Completar no app Reminders não atualiza `TaskItem`.

### Project Intelligence

- [ ] **`DynamicAnalysis` genérico vs `MeetingAnalysis` legado — dois formatos coexistindo sem migração.**
- [ ] **`Project.frameworkSchema` armazenado como JSON String — sem tipagem.** Erros de parsing só em runtime.
- [ ] **`GraphEdgeService` sem queries de grafo reais.** Sem path finding, connected components, ou centrality.
- [ ] **`ProjectGraphView` é estática (lista de edges).** Sem visualização interativa, sem navegação por nós.
- [ ] **`TaskItem` não tem `assigneeID` — tasks não podem ser atribuídas a `Person`.**
- [ ] **`TaskItem.status` sem tracking de quando mudou.** Sem histórico de transições.
- [ ] **`Person` model criado mas sem integração com Contacts.** `ContactsService` existe para speaker matching mas não popula `Person` automaticamente.

### Context Sensors

- [ ] **`ContextCaptureService` faz 7 chamadas de sensor síncronas no início da gravação.** Adiciona latência antes do microfone abrir.
- [ ] **`LocationSensor` captura localização no início mas não atualiza durante.** Reunião em movimento perde contexto.
- [ ] **`MotionActivitySensor` captura dados mas não persiste no `KnowledgeItem`.** Só loga, não salva.
- [ ] **`AudioRouteSensor` não avisa quando a rota muda durante gravação.** Bluetooth desconecta no meio → usuário não sabe.

### Performance & Memory

- [ ] **`prepareForRecognition` aloca buffer PCM inteiro do arquivo de entrada.** Para áudio de 2h a 44.1kHz stereo, ~635MB de RAM.
- [ ] **`KnowledgeDetailView` mantém transcript, analysis, rawAnalysisJSON, scannedPages em memória simultaneamente.** 4+ cópias do mesmo conteúdo.
- [ ] **`MonthGridView` renderiza todos os 30-31 dias do mês sem lazy loading.**
- [ ] **`FileArtifactStore` sem cache de leitura.** Lê do disco toda vez que a view é renderizada.
- [ ] **`Timer.scheduledTimer` com 0.05s interval para observation — 20 wakeups/segundo.** Drena bateria durante gravação.
- [ ] **`FileArtifactStore` faz `FileManager.default.fileExists()` antes de cada acesso.** Duas syscalls por leitura.
- [ ] **Sem verificação de espaço necessário antes de gravar.** 50MB mínimo hardcoded — gravação de 2h pode precisar de 200MB+.

### Error Handling & Resilience

- [ ] **`RecordingManifest` escrito como JSON atômico sem `atomic write`.** Crash no meio do write → JSON truncado.
- [ ] **Sem checksum ou hash dos arquivos de áudio.** Arquivo corrompido só detectado quando transcrição falha.
- [ ] **`ContentPipelineService.process()` pode rodar por minutos no background sem `UIApplication.beginBackgroundTask`.** Se o app vai para background, pipeline é suspenso.
- [ ] **Sem `BGTaskScheduler` para pipeline.** Transcrição/Análise não continuam em background.
- [ ] **Erros de pipeline não expostos na Inbox.** Item com `.failed` parece igual a item `.draft`.

### DevX & Tooling

- [ ] **`CLAUDE.md` desatualizado.** Lista Live Activities como "implemented" (removido). Não documenta pipeline de log, correções de transcrição, nem `device-config.sh`.
- [ ] **`docs/` com 15+ documentos sem índice central.** Documentos de fases antigas misturados com atuais.
- [ ] **Sem docstrings em métodos críticos.** `startRecording()`, `process()`, `forceFinish()` — comportamentos complexos sem documentação inline.
- [ ] **`make deploy` com `APP_PATH` hardcoded.** Caminho do DerivedData fixo — clean build quebra instalação.
- [ ] **Sem SwiftLint/SwiftFormat.** `try?` vs `try`, `guard let` vs `if let` inconsistentes.
- [ ] **Sem CI/CD.** Nenhum GitHub Actions, Xcode Cloud.

### Security & Network

- [ ] **Provider API keys enviadas sem certificate pinning.** MitM em WiFi pública pode interceptar keys.
- [ ] **Sem rotação de API keys.** Keys ficam no Keychain até o usuário mudar manualmente.
- [ ] **Sem validação de URL do provider.** Provider malicioso com URL parecida pode receber dados.
- [ ] **`RemoteTranscriptionEngine` envia áudio completo para servidor externo sem informar o usuário.** Nenhum aviso "seu áudio será enviado para servidores externos".
- [ ] **Sem `NWPathMonitor` ou detecção de offline.** App não sabe se está online.
- [ ] **Sem retry com backoff para chamadas de API.** Falha de rede → `maxAttempts = 2` sem delay.

### AI Best Practices

- [ ] **Sem detecção de participantes (speaker diarization).** `ContactsService` existe mas não integrado à transcrição.
- [ ] **Sem extração de action items automática pós-transcrição.** Depende do agente de análise — que só roda se provider configurado.
- [ ] **Sem marcadores de "momento importante" durante gravação.** Usuário não pode marcar um ponto no tempo.
- [ ] **Sem prompt injection guardrails.** Se o transcript contém "ignore previous instructions", o agente pode ser manipulado.

---

## 🟢 P3 — Itens de polish e futuro (não listados aqui)

Aproximadamente 1900 itens P3 foram capturados no audit mas não estão nesta lista consolidada. Incluem:

- Polish visual (animações, micro-interações, haptics, sons)
- Features futuras (WidgetKit, App Intents, Siri, Mac Catalyst, Apple Watch)
- Integrações externas (Slack, Notion, Zoom, Things, GitHub)
- Gamificação, analytics, marketing, comunidade
- Padrões de código (todos os GoF patterns)
- Bibliotecas Swift externas (Lottie, Nuke, TCA, etc.)
- Negócio e estratégia (monetização, ASO, pricing)
- Edge cases obscuros (emoji em path, arquivo zero bytes, etc.)
- WCAG completo, OWASP Mobile Top 10, HIG compliance

Esses itens estão documentados no histórico de iterações (1-47) no git log deste arquivo.

---

## 📊 Resumo

| Prioridade | Contagem | Foco |
|-----------|----------|------|
| P0 | 6 | Crash, perda de dados, segurança crítica |
| P1 | 28 | Fluxo quebrado, UX comprometida |
| P2 | 80 | Atrito, dívida técnica, qualidade |

**Total acionável: ~114 itens** (vs ~2000 no dump original)

### Ordem de ataque sugerida

1. **Semana 1:** P0s (3 crashes + 2 security + 1 data)
2. **Semanas 2-3:** P1 de Audio/Recording (estabilidade do pipeline core)
3. **Semanas 4-5:** P1 de Agent/UI (visibilidade, feedback ao usuário)
4. **Semanas 6-7:** P1 de Data Layer/Architecture (refactors estruturais)
5. **Semanas 8+:** P2s por área conforme necessidade
