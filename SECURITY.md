# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

Wawa Note leva a segurança a sério. O app é local-first — seus dados nunca saem do dispositivo sem sua configuração explícita de um provider de IA.

**Se você descobrir uma vulnerabilidade de segurança:**

1. **NÃO abra uma issue pública**
2. Envie um email para o maintainer com detalhes
3. Inclua passos para reproduzir e impacto potencial
4. Aguarde confirmação antes de divulgar publicamente

## Security Design

- **API keys**: armazenadas no Keychain, nunca em UserDefaults ou arquivos planos
- **Dados do usuário**: armazenados localmente (SwiftData + FileManager)
- **Comunicação com providers**: HTTPS exclusivamente
- **Biometria**: Face ID disponível como gate opcional
- **Gravações de áudio**: armazenadas localmente, transcrição opcional
- **Sem backend**: não há servidores, contas, ou sincronização na nuvem

## Provider Security

Wawa Note é provider-agnostic. Você controla:
- Qual provider usar
- Qual endpoint (incluindo localhost para modelos locais)
- Quais dados enviar para processamento

Nenhum dado é enviado a providers sem sua configuração explícita.
