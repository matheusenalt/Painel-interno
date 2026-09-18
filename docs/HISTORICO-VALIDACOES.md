# Histórico de validações relevantes

Este arquivo registra por que determinadas proteções existem. Ele não contém IP, domínio, usuário pessoal nem credencial de produção.

## Baseline 1 — provisionamento

- instalação-base v1.17 executada em VPS Linux;
- containers Nextcloud, MariaDB, Redis, FoxDesk e MariaDB do FoxDesk subiram corretamente;
- configuração declarativa validada após transformar e-mail ausente de erro fatal em aviso;
- HTTPS ainda estava pendente porque DNS/Caddy não haviam sido concluídos;
- healthcheck também mostrou um falso positivo na leitura do slogan do Nextcloud.

## Baseline 2 — estabilização e backup externo

- DNS/reverse proxy/HTTPS concluídos;
- acesso público dos dois serviços validado;
- conta SFTP restrita e chave pública da VM de backup validadas;
- primeiro snapshot real puxado para o HD externo e conferido por SHA-256;
- o fluxo não interativo de SFTP foi ajustado para usar stdin em vez de `/dev/fd`;
- correção de collation explícita aplicada no módulo de Gestão de Equipe para consultas de e-mail no FoxDesk.

## Baseline 3 — DR comprovado

- corrigida a detecção do filesystem real do HD após `x-systemd.automount`;
- corrigido o teste de disponibilidade do endpoint SFTP no notebook host;
- corrigida a validação de status para não aceitar `last-run.json` de execução anterior;
- restore local validado;
- restore externo validado usando `.tar.gz` + SHA-256;
- o fluxo criou snapshot de segurança antes do rollback, restaurou volumes/bancos, limpou Redis e recriou os serviços;
- após correção do parser do slogan, o restore externo final terminou com `Status: success` e healthcheck sem falhas.

### Restore externo de referência

```text
Tipo: restore
Status: success
Resultado: operação concluída e estado restaurado validado pelo healthcheck.
```

Esses testes justificam manter no repositório as correções de SFTP, automount, healthcheck, snapshot pré-restore e validação de checksums.
