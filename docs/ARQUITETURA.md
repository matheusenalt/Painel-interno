# Arquitetura de recuperação do Portal Interno

```text
Internet
  -> DNS
  -> Caddy / HTTPS na VPS
     -> Nextcloud (Docker, localhost)
     -> FoxDesk   (Docker, localhost)

Nextcloud -> MariaDB + Redis
FoxDesk   -> MariaDB

Backup:
VPS -> snapshot .tar.gz + .sha256 -> SFTP somente leitura
    -> VM Debian de backup -> HD externo
```

## Princípios

- O Git contém **código e documentação**, nunca segredos.
- O snapshot contém **estado e dados** e deve ser tratado como material sensível.
- O modo `do-zero` cria um novo estado a partir de configuração local.
- O modo `from-backup` usa o repositório como runtime conhecido e o snapshot como fonte de dados/segredos operacionais restaurados.
- O Caddy é configurado somente depois de o DNS apontar para a nova VPS.
- Backup só é considerado confiável depois de um restore validado.
