# Changelog

## 2026-09 — edição pública sanitizada

- Removidas identidade visual, nomes, e-mails, domínios, IPs públicos e referências organizacionais.
- Padronizados nomes internos para `portal-*` e caminhos genéricos em `/opt/portal-interno`.
- Removida documentação executiva/interna que não faz parte do material de portfólio.
- Mantidos scripts de provisionamento, backup, restore, HTTPS, healthcheck e DR.
- Mantida a camada de tradução dos e-mails FoxDesk para pt-BR.
- Branding passou a ser opcional e sem assets versionados.
- Configurações reais continuam excluídas pelo `.gitignore`.

## 2026-09 — padronização de e-mails FoxDesk pt-BR

- Patch idempotente aplicado durante build e após restore.
- Templates pt-BR para chamados, comentários, atribuição, status, senha, boas-vindas, tarefas recorrentes, timer e prazos.
- Healthcheck inclui validações da camada pt-BR.

## 2026-09 — baseline de Disaster Recovery

- Dois caminhos documentados: instalação do zero e reconstrução por snapshot.
- Restore externo validado antes da publicação da edição sanitizada.
- Corrigidos casos reais envolvendo SFTP não interativo, automount exFAT, status antigo da VM e parser do healthcheck.
- Backup inclui configuração operacional necessária à recuperação, preservando segredos somente nos snapshots protegidos.
- Adicionada adaptação opcional para host Windows da VM de backup.

## Publicação sanitizada — revisão pré-GitHub

- Bind padrão de Nextcloud e FoxDesk alterado para `127.0.0.1`.
- Versões exatas removidas dos exemplos públicos; o deploy passa a exigir versões aprovadas explicitamente.
- Comentários específicos do ambiente de origem foram generalizados.
- Checklist de publicação ampliado com privacidade do e-mail de commit, denylist externa e revisão de mídia para LinkedIn.
