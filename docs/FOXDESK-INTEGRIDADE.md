# Integridade do pacote FoxDesk

O build do FoxDesk baixa um tarball da versão definida em `versions.foxdesk`. Para que a reconstrução não aceite silenciosamente um arquivo diferente do aprovado, o perfil de produção exige o campo `versions.foxdesk_sha256` com **64 caracteres hexadecimais**.

## Como obter o valor

1. Defina a versão que será aprovada, por exemplo uma versão estável da família `0.3.x`.
2. Prefira um checksum oficial publicado pelo projeto upstream, quando existir.
3. Se o upstream não publicar checksum, baixe o tarball da tag oficial em uma estação confiável e calcule o SHA-256 antes da mudança entrar no baseline:

```bash
./scripts-repo/calcular-foxdesk-sha256.sh VERSAO_EXATA_APROVADA
```

4. Registre o hash aprovado no `portal.json` **local/não versionado**:

```json
"versions": {
  "foxdesk": "VERSAO_EXATA_APROVADA",
  "foxdesk_sha256": "COLE_AQUI_OS_64_CARACTERES_HEXADECIMAIS"
}
```

5. Execute o provisionamento. O Dockerfile compara o hash antes de extrair o pacote e aborta o build se houver divergência.

## Quando atualizar

Sempre que `versions.foxdesk` mudar, calcule/valide novamente o checksum. Não reutilize o hash de outra versão.

> O SHA-256 não é uma credencial e pode ser documentado. O que não deve ir ao Git são senhas, tokens, chaves privadas e configurações reais da infraestrutura.
