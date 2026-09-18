# Como manter este repositório útil no futuro

Este repositório deve representar **como reconstruir o ambiente atual**, não apenas como ele era na primeira implantação.

Sempre que houver uma melhoria relevante — por exemplo um novo serviço Docker, mudança de proxy, novo app do Nextcloud, mudança no FoxDesk ou nova política de segurança — faça o seguinte no mesmo conjunto de alterações:

1. Atualize o código/runtime correspondente em `install/runtime/`.
2. Se o novo componente possuir dados persistentes, inclua-os em `backup/backup.sh`.
3. Ensine `backup/validate-backup.py` a validar os novos artefatos do snapshot.
4. Atualize `backup/restore.sh` e `install/install-from-backup.sh` para reconstruí-los.
5. Adicione a validação do componente em `healthcheck/healthcheck.sh` e, quando fizer sentido, em `auditar-seguranca.sh`.
6. Atualize o `README.md` com qualquer etapa nova que outro técnico precise executar.
7. Registre a mudança em `CHANGELOG.md`.
8. Execute um backup de teste e um restore controlado antes de considerar a mudança pronta para DR.
9. Rode `./scripts-repo/scan-secrets.sh` antes do commit.

## Regra prática

Se um arquivo/serviço for necessário para o Portal Interno voltar a funcionar depois da perda total da VPS, ele precisa estar em um destes lugares:

- **Git:** código, estrutura e documentação sem segredos; ou
- **Backup:** dados/estado/segredos operacionais que não podem ir ao Git.

Se não estiver em nenhum dos dois, ele não está protegido para desastre.
