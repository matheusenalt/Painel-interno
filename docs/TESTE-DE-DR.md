# Teste periódico de Disaster Recovery

Faça este teste em VPS/VM descartável ou janela controlada. Não use produção para experimentar um procedimento novo.

1. Pegue uma cópia externa recente do `.tar.gz` e `.sha256`.
2. Suba uma VPS Linux limpa compatível.
3. Clone/copie este repositório.
4. Execute `install/install-from-backup.sh`.
5. Aponte DNS de teste ou use domínios apropriados ao ensaio.
6. Execute `configurar-https.sh` quando o DNS estiver pronto.
7. Execute `healthcheck.sh` e `auditar-seguranca.sh`.
8. Valide Nextcloud: login, arquivos, Team Folders, calendários e apps críticos.
9. Valide FoxDesk: login, histórico, chamados e anexos.
10. Valide Gestão de Equipe se houver `host-config.tar.gz`/configuração segura disponível.
11. Gere um novo backup na máquina reconstruída.
12. Confirme que a VM externa consegue puxar e validar esse novo snapshot.
13. Registre data, snapshot, duração, falhas e correções em `CHANGELOG.md` ou no sistema interno de documentação.

Um backup só deve ser considerado confiável quando a restauração for comprovada.
