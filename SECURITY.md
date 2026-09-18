# Segurança do repositório público

Este repositório é uma versão **sanitizada para estudo e portfólio**. Ele não deve ser usado como cofre de credenciais nem receber dados reais de uma implantação.

## Nunca versionar

- `install/config/portal.json` preenchido;
- `install/config/team.json` preenchido;
- `.env` real;
- snapshots `.tar.gz` e arquivos `.sha256` de produção;
- dumps SQL;
- chaves SSH privadas ou públicas usadas em produção;
- senhas, tokens, cookies ou certificados privados;
- strings de conexão com credenciais;
- endereços IP públicos reais;
- domínios e e-mails reais;
- logs contendo dados identificáveis;
- arquivos de branding de organizações reais.

Os arquivos `*.example` existem somente para mostrar a estrutura esperada.

## Scanner local

Antes de qualquer push:

```bash
./scripts-repo/pre-push-check.sh
```

Para executar apenas a varredura básica:

```bash
./scripts-repo/scan-secrets.sh
```

O scanner é uma camada adicional de proteção e **não substitui revisão humana**.

## Branding

A pasta `install/runtime/branding/` contém apenas instruções. Nenhuma identidade visual real é distribuída na edição pública.

Caso queira testar branding próprio, adicione localmente arquivos de demonstração conforme o README da pasta e evite enviar marcas que você não tenha autorização para publicar.

## Uso em ambiente real

Antes de usar este projeto fora de laboratório:

1. revise todos os scripts;
2. fixe versões e checksums aprovados;
3. valide firewall, SSH, DNS e TLS;
4. configure segredos fora do Git;
5. execute backup;
6. execute restore controlado;
7. confirme o healthcheck final.
