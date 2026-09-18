# Backup e restore da VPS

Os scripts desta pasta são as cópias canônicas para documentação/DR. Na instalação, suas versões equivalentes ficam em `/opt/portal-interno/scripts/`.

- `backup.sh`: snapshot consistente dos dois aplicativos e bancos.
- `restore.sh`: rollback em uma VPS que já possui o runtime.
- `validate-backup.py`: valida nomes, checksums e estrutura segura do snapshot antes da extração.
- `configure-backup-server.sh`: cria exportação SFTP somente leitura.
- `configurar-chave-backup.sh`: autoriza somente a chave pública da VM externa.

Para uma VPS completamente vazia, use `../install/install-from-backup.sh` em vez de chamar `restore.sh` diretamente.
