# Contributing to Wawa Note

Obrigado pelo interesse em contribuir! Wawa Note é um app iOS open-source e provider-agnostic para workspace de conhecimento com IA.

## Como Contribuir

### Reportando Bugs

1. Verifique se o bug já não foi reportado em [Issues](https://github.com/wsmontes/wawa-note-ios/issues)
2. Use o template de bug report
3. Inclua: versão do iOS, modelo do dispositivo, provider configurado, passos para reproduzir, logs relevantes

### Sugerindo Features

1. Verifique se a feature já não foi sugerida
2. Use o template de feature request
3. Explique o caso de uso e por que é valioso

### Pull Requests

1. **Fork o repo** e crie seu branch a partir de `main`
2. **Siga os coding standards** em `docs/CODING_STANDARDS.md`
3. **Teste** suas mudanças em dispositivo real ou simulator
4. **Atualize a documentação** se necessário
5. **Use commits atômicos** com mensagens claras
6. Abra o PR contra `main`

### Convenções de Código

- **Swift 6.0** com `async/await` e `@MainActor`
- **SwiftUI** para views (mantenha-as finas — lógica nos services)
- **Protocol-first**: toda integração externa deve ter um protocolo
- **Nunca hardcode** API keys, URLs de provider, ou segredos
- **Use `AIConfigService.shared.requestParams(for:model:)`** para toda chamada de IA
- **Keychain** para API keys, **FileManager** para artefatos, **SwiftData** para metadados
- Testes unitários são bem-vindos mas não obrigatórios para PRs pequenos

### Estrutura de Branches

```
main              — produção, estável
KAN-XX/descricao  — branch vinculada a issue JIRA (preferido)
feature/*         — novas funcionalidades (sem JIRA)
fix/*             — correções de bugs (sem JIRA)
docs/*            — documentação
```

### JIRA Integration

This project is tracked at https://wawasoftbc.atlassian.net (project key: **KAN**).

- **Branch names** must include the JIRA key: `KAN-73/fix-aac-speech-gaps`
- **Commit messages** must reference the issue: `KAN-73: switch AudioChunker to PCM WAV output`
- **PRs** should mention the issue key in the title or description for auto-linking
- Every source file has `// Related JIRA: KAN-XX` comments — keep them current

### Setup de Desenvolvimento

```bash
git clone https://github.com/wsmontes/wawa-note-ios.git
cd wawa-note-ios
open wawa-note.xcodeproj
```

Você precisa de:
- Xcode 16+
- iOS 17.0+ device ou simulator
- Pelo menos uma API key de provider de IA

### Dúvidas?

Abra uma [issue](https://github.com/wsmontes/wawa-note-ios/issues) ou participe das [discussions](https://github.com/wsmontes/wawa-note-ios/discussions).
