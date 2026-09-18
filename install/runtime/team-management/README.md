# Gestão de Equipe

Complemento administrativo do Portal Interno.

## O que faz

- sincroniza os e-mails já preenchidos em `team.json` com os usuários existentes do Nextcloud;
- cria no FoxDesk, como `agent`, as contas correspondentes aos usuários que já possuem e-mail;
- quem ainda estiver sem e-mail continua normalmente no Nextcloud e fica com FoxDesk pendente;
- pelo app **Gestão de Equipe**, Gestão/Admin podem:
  - cadastrar funcionário novo com ou sem e-mail;
  - adicionar e-mail posteriormente; ao salvar, a conta FoxDesk é criada automaticamente;
  - alterar um e-mail existente; a mesma conta FoxDesk é atualizada, preservando perfil/histórico;
  - trocar entre os setores permitidos;
  - desligar funcionário, excluindo a conta Nextcloud e desativando FoxDesk para preservar histórico;
- o setor `admin` nunca é oferecido e o backend também bloqueia alterações/desligamento de contas administrativas;
- configura tema/favicon e SMTP conforme `team.json`.

## Configuração

O arquivo real `team.json` não faz parte do repositório. Use `install/config/team.json.example` como modelo, entregue a configuração real por canal seguro e informe `TEAM_CONFIG_SRC=/caminho/seguro/team.json`. E-mails vazios são aceitos e deixam o FoxDesk pendente.

## Instalação

```bash
sudo TEAM_CONFIG_SRC=/caminho/seguro/team.json \
  /opt/portal-interno/team-management/install-team-management.sh
```

Se SMTP estiver habilitado, a senha da conta SMTP será solicitada no terminal e não é gravada no JSON.

## Arquivos persistentes

- `/etc/portal-interno/team.json`
- `/usr/local/lib/team-management/team-control.py`
- `/etc/systemd/system/team-control.service`
- `/root/portal-credenciais-equipe.txt`
- `/var/log/team-management-actions.jsonl`

O app Nextcloud é instalado em `/var/www/html/custom_apps/teammanager` dentro do container e habilitado apenas para os grupos `admin` e `gestao`.

## Senha temporária padronizada

O campo `employee_management.temporary_password` define a senha inicial usada para novas contas criadas pelo painel e para contas FoxDesk provisionadas quando um e-mail é adicionado. Se o campo for removido ou ficar vazio, o sistema volta a gerar senhas aleatórias.

A senha é apenas temporária e deve ser trocada pelo funcionário no primeiro acesso. O arquivo `/etc/portal-interno/team.json` é instalado com permissão `0600`.
