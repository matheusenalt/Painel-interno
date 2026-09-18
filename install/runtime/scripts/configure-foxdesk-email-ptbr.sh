#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

log(){ printf '\n[FoxDesk pt-BR] %s\n' "$*"; }
die(){ printf '\nERRO: %s\n' "$*" >&2; exit 1; }

for c in portal-foxdesk portal-foxdesk-db; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" == "true" ]] \
    || die "container $c não está em execução."
done

log "Aplicando patch idempotente dos e-mails no volume do FoxDesk..."
docker exec portal-foxdesk test -f /usr/local/bin/apply-portal-ptbr.php \
  || die "patch /usr/local/bin/apply-portal-ptbr.php ausente da imagem FoxDesk."
docker exec portal-foxdesk php /usr/local/bin/apply-portal-ptbr.php /var/www/html

log "Criando/atualizando templates pt-BR no banco..."
cat <<'SQL' | docker exec -e MYSQL_PWD="$FOX_DB_PASSWORD" -i portal-foxdesk-db \
  mariadb -u"$FOX_DB_USER" "$FOX_DB_NAME"
INSERT INTO email_templates (template_key,language,subject,body,is_active) VALUES
('status_change','pt-BR','Status atualizado no chamado #{ticket_id}: {ticket_title}',
 'Olá,\n\nO status do seu chamado "{ticket_title}" foi alterado.\n\nStatus anterior: {old_status}\nNovo status: {new_status}\n\nComentário:\n{comment_text}\n\nTempo registrado: {time_spent}\n\nVer chamado: {ticket_url}\n\nAtenciosamente,\n{app_name}',1),
('new_comment','pt-BR','Novo comentário no chamado #{ticket_id}: {ticket_title}',
 'Olá,\n\nUm novo comentário foi adicionado ao chamado "{ticket_title}".\n\nPor: {commenter_name}\nTempo registrado: {time_spent}\nAnexos: {attachments}\n\n---\n{comment_text}\n---\n\nVer comentário: {comment_url}\n\nAtenciosamente,\n{app_name}',1),
('new_ticket','pt-BR','Novo chamado #{ticket_id}: {ticket_title}',
 'Olá,\n\nUm novo chamado foi criado.\n\nAssunto: {ticket_title}\nTipo: {ticket_type}\nPrioridade: {priority}\nSolicitante: {user_name} ({user_email})\n\nVer chamado: {ticket_url}\n\nAtenciosamente,\n{app_name}',1),
('password_reset','pt-BR','Redefinição de senha',
 'Olá,\n\nFoi solicitada uma redefinição de senha.\n\nUtilize o link abaixo:\n{reset_link}\n\nEste link é válido por 1 hora.\n\nSe você não solicitou esta redefinição, ignore este e-mail.\n\nAtenciosamente,\n{app_name}',1),
('ticket_confirmation','pt-BR','Chamado recebido #{ticket_code}: {ticket_title}',
 'Olá,\n\nSeu chamado #{ticket_code} "{ticket_title}" foi recebido com sucesso.\n\nManteremos você atualizado sobre o andamento.\n\nVer chamado: {ticket_url}\n\nAtenciosamente,\n{app_name}',1),
('ticket_assignment','pt-BR','Chamado atribuído a você #{ticket_code}: {ticket_title}',
 'Olá, {agent_name},\n\nUm chamado foi atribuído a você.\n\nChamado: #{ticket_code}\nAssunto: {ticket_title}\nAtribuído por: {assigner_name}\n\nVer chamado: {ticket_url}\n\nAtenciosamente,\n{app_name}',1),
('recurring_task_assignment','pt-BR','Nova tarefa recorrente atribuída: {ticket_title}',
 'Olá, {recipient_name},\n\nUma tarefa recorrente gerou um novo chamado para você.\n\nChamado: #{ticket_code}\nTítulo: {ticket_title}\nDescrição: {ticket_description}\nPrazo: {due_date}\n\nVer chamado: {ticket_url}\n\nAtenciosamente,\n{app_name}',1),
('long_timer_alert','pt-BR','Cronômetro ativo por tempo excessivo - Chamado #{ticket_code}',
 'Olá, {user_name},\n\nSeu cronômetro está em execução há {elapsed_time} no chamado "{ticket_title}".\n\nIniciado em: {started_at}\nChamado: #{ticket_code} - {ticket_title}\n\nVerifique se você esqueceu de encerrar o cronômetro.\n\nVer chamado: {ticket_url}\n\nAtenciosamente,\nEquipe {app_name}',1),
('welcome_email','pt-BR','Bem-vindo(a) ao {app_name}',
 'Olá, {name},\n\nSua conta foi criada.\n\nE-mail: {email}\nSenha: {password}\n\nAcesso: {login_url}\n\nApós entrar no sistema, você poderá alterar sua senha nas configurações do perfil.\n\nAtenciosamente,\n{app_name}',1)
ON DUPLICATE KEY UPDATE
  subject=VALUES(subject),
  body=VALUES(body),
  is_active=VALUES(is_active);
SQL

log "Validando sintaxe dos arquivos alterados..."
docker exec portal-foxdesk php -l /var/www/html/includes/mailer.php >/dev/null
docker exec portal-foxdesk php -l /var/www/html/includes/modules/email/email-renderer.php >/dev/null
docker exec portal-foxdesk php -l /var/www/html/includes/lang/pt-BR.php >/dev/null

count="$(docker exec -e MYSQL_PWD="$FOX_DB_PASSWORD" portal-foxdesk-db \
  mariadb --batch --skip-column-names -u"$FOX_DB_USER" "$FOX_DB_NAME" \
  -e "SELECT COUNT(*) FROM email_templates WHERE language='pt-BR' AND is_active=1 AND template_key IN ('status_change','new_comment','new_ticket','password_reset','ticket_confirmation','ticket_assignment','recurring_task_assignment','long_timer_alert','welcome_email');" 2>/dev/null || true)"
[[ "$count" == "9" ]] || die "templates pt-BR incompletos no banco (encontrados=${count:-0}, esperados=9)."

log "E-mails do FoxDesk padronizados em pt-BR (9 templates + renderer HTML)."
