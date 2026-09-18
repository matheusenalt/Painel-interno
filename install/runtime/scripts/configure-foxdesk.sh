#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
CREDENTIALS_FILE="/root/portal-credenciais-iniciais.txt"
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

FOXDESK_PORT="${FOXDESK_PORT:-8081}"
HOST_IP="${HOST_IP:-127.0.0.1}"
FOXDESK_PUBLIC_URL="${FOXDESK_PUBLIC_URL:-http://${HOST_IP}:${FOXDESK_PORT}}"
FOXDESK_ADMIN_EMAIL="${FOXDESK_ADMIN_EMAIL:-admin@exemplo.invalid}"
FOXDESK_ADMIN_PASSWORD="${FOXDESK_ADMIN_PASSWORD:-}"

log(){ printf '\n[FoxDesk] %s\n' "$*"; }
warn(){ printf '\n[AVISO] %s\n' "$*" >&2; }
die(){ printf '\nERRO: %s\n' "$*" >&2; exit 1; }

[[ -n "$FOXDESK_ADMIN_PASSWORD" ]] || die "informe FOXDESK_ADMIN_PASSWORD no ambiente ao executar este script."
[[ ${#FOXDESK_ADMIN_PASSWORD} -ge 12 ]] || die "a senha do Admin FoxDesk precisa ter no mínimo 12 caracteres."
[[ "$FOXDESK_ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "e-mail do Admin FoxDesk inválido: $FOXDESK_ADMIN_EMAIL"

for c in portal-foxdesk portal-foxdesk-db; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" == "true" ]] \
    || die "container $c não está em execução."
done

log "Aguardando aplicação responder..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${FOXDESK_PORT}/" >/dev/null 2>&1 \
     || curl -fsS "http://127.0.0.1:${FOXDESK_PORT}/install.php" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[[ "$ready" == "1" ]] || {
  docker logs --tail 100 portal-foxdesk >&2 || true
  die "FoxDesk não respondeu por HTTP dentro do tempo esperado."
}

if docker exec portal-foxdesk test -s /var/www/html/config.php >/dev/null 2>&1; then
  log "FoxDesk já instalado; mantendo banco e reaplicando padronização pt-BR."
else
  log "Inicializando FoxDesk diretamente, sem automatizar o formulário web..."
  # O instalador web do FoxDesk usa sessão/CSRF e é voltado para interação humana.
  # Para um deploy reproduzível, fazemos as mesmas etapas de bootstrap diretamente:
  # banco -> schema -> usuário admin -> defaults -> config.php.

  log "Recriando banco vazio do FoxDesk..."
  docker exec portal-foxdesk-db mariadb -uroot -p"$FOX_DB_ROOT_PASSWORD" -e \
    "DROP DATABASE IF EXISTS \`$FOX_DB_NAME\`; CREATE DATABASE \`$FOX_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$FOX_DB_NAME\`.* TO '$FOX_DB_USER'@'%'; FLUSH PRIVILEGES;"

  log "Importando schema oficial da versão ${FOXDESK_VERSION:-versão configurada}..."
  docker exec portal-foxdesk test -s /var/www/html/includes/schema.sql \
    || die "includes/schema.sql não existe dentro do container FoxDesk."
  docker exec portal-foxdesk cat /var/www/html/includes/schema.sql \
    | docker exec -i portal-foxdesk-db mariadb -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME"

  log "Criando conta administrativa e dados iniciais..."
  ADMIN_HASH="$(docker exec \
    -e FOXDESK_BOOTSTRAP_PASSWORD="$FOXDESK_ADMIN_PASSWORD" \
    portal-foxdesk php -r 'echo password_hash(getenv("FOXDESK_BOOTSTRAP_PASSWORD"), PASSWORD_DEFAULT);')"
  [[ -n "$ADMIN_HASH" ]] || die "não foi possível gerar o hash da senha do Admin."

  # O e-mail foi validado acima e o hash gerado pelo PHP não contém aspas simples.
  cat <<SQL | docker exec -i portal-foxdesk-db mariadb -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME"
INSERT INTO users (email,password,first_name,last_name,role,is_active,language,created_at)
VALUES ('$FOXDESK_ADMIN_EMAIL','$ADMIN_HASH','Admin','Portal','admin',1,'pt-BR',NOW());

INSERT INTO statuses (name,slug,color,sort_order,is_default,is_closed) VALUES
('Novo','new','#0a84ff',1,1,0),
('Em validação','testing','#5e5ce6',4,0,0),
('Aguardando retorno','waiting','#ff9f0a',3,0,0),
('Em andamento','processing','#30b0c7',2,0,0),
('Concluído','done','#34c759',5,0,1);

INSERT INTO priorities (name,slug,color,icon,sort_order,is_default) VALUES
('Baixa','low','#34c759','fa-arrow-down',1,0),
('Média','medium','#0a84ff','fa-minus',2,1),
('Alta','high','#ff9f0a','fa-arrow-up',3,0),
('Urgente','urgent','#ff3b30','fa-exclamation',4,0);

INSERT INTO ticket_types (name,slug,icon,color,sort_order,is_default) VALUES
('Geral','general','fa-file-alt','#0a84ff',1,1),
('Orçamento','quote','fa-coins','#ff9f0a',2,0),
('Dúvida','inquiry','fa-question-circle','#5e5ce6',3,0),
('Erro','bug','fa-bug','#ff3b30',4,0);

INSERT INTO settings (setting_key,setting_value) VALUES
('app_name','Portal Interno'),
('ticket_prefix','TKT'),
('login_welcome_text','Portal de chamados demonstrativo'),
('app_language','pt-BR'),
('time_format','24'),
('currency','BRL'),
('smtp_host',''),
('smtp_port','587'),
('smtp_user',''),
('smtp_pass',''),
('smtp_from_email','$FOXDESK_ADMIN_EMAIL'),
('smtp_from_name','Portal Interno'),
('smtp_encryption','tls'),
('email_notifications_enabled','0'),
('notify_on_status_change','1'),
('notify_on_new_comment','1'),
('notify_on_new_ticket','1'),
('imap_enabled','0'),
('imap_host',''),
('imap_port','993'),
('imap_encryption','ssl'),
('imap_username',''),
('imap_password',''),
('imap_folder','INBOX'),
('imap_processed_folder','Processed'),
('imap_failed_folder','Failed'),
('imap_max_emails_per_run','50'),
('imap_max_attachment_size_mb','10'),
('imap_validate_cert','0'),
('imap_mark_seen_on_skip','1'),
('imap_allow_unknown_senders','0'),
('imap_storage_base','storage/tickets'),
('imap_deny_extensions','php,phtml,php3,php4,php5,phar,exe,bat,cmd,js,vbs,ps1,sh'),
('pseudo_cron_enabled','1');
SQL

  # Templates padrão equivalentes aos criados pelo instalador oficial.
  cat <<'SQL' | docker exec -i portal-foxdesk-db mariadb -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME"
INSERT INTO email_templates (template_key,subject,body,is_active) VALUES
('status_change','Status changed for ticket #{ticket_id}: {ticket_title}',
 'Hello,\n\nThe status of your ticket "{ticket_title}" has changed.\n\nPrevious status: {old_status}\nNew status: {new_status}\n\nView ticket: {ticket_url}\n\nRegards,\n{app_name}',1),
('new_comment','New comment on ticket #{ticket_id}: {ticket_title}',
 'Hello,\n\nA new comment was added to your ticket "{ticket_title}".\n\nFrom: {commenter_name}\nTime spent: {time_spent}\nAttachments: {attachments}\n\n---\n{comment_text}\n---\n\nView comment: {comment_url}\n\nRegards,\n{app_name}',1),
('new_ticket','New ticket #{ticket_id}: {ticket_title}',
 'Hello,\n\nA new ticket has been created.\n\nSubject: {ticket_title}\nType: {ticket_type}\nPriority: {priority}\nFrom: {user_name} ({user_email})\n\nView ticket: {ticket_url}\n\nRegards,\n{app_name}',1),
('password_reset','Password reset',
 'Hello,\n\nYou requested a password reset. Click the link below:\n{reset_link}\n\nThis link is valid for 1 hour.\n\nIf you did not request a password reset, please ignore this email.\n\nRegards,\n{app_name}',1);
SQL

  log "Gerando config.php..."
  APP_URL="$FOXDESK_PUBLIC_URL"
  docker exec -i \
    -e CFG_DB_HOST="foxdesk-db" \
    -e CFG_DB_PORT="3306" \
    -e CFG_DB_NAME="$FOX_DB_NAME" \
    -e CFG_DB_USER="$FOX_DB_USER" \
    -e CFG_DB_PASS="$FOX_DB_PASSWORD" \
    -e CFG_APP_URL="$APP_URL" \
    portal-foxdesk php <<'PHP'
<?php
$dbHost = getenv('CFG_DB_HOST');
$dbPort = getenv('CFG_DB_PORT');
$dbName = getenv('CFG_DB_NAME');
$dbUser = getenv('CFG_DB_USER');
$dbPass = getenv('CFG_DB_PASS');
$appUrl = getenv('CFG_APP_URL');
$secret = bin2hex(random_bytes(32));
$config = "<?php\n/**\n * FoxDesk - Configuration\n * Generated by Portal Interno provisioner\n */\n\n"
    . "define('DB_HOST', " . var_export($dbHost, true) . ");\n"
    . "define('DB_PORT', " . var_export($dbPort, true) . ");\n"
    . "define('DB_NAME', " . var_export($dbName, true) . ");\n"
    . "define('DB_USER', " . var_export($dbUser, true) . ");\n"
    . "define('DB_PASS', " . var_export($dbPass, true) . ");\n\n"
    . "define('SECRET_KEY', " . var_export($secret, true) . ");\n\n"
    . "define('APP_NAME', 'Portal Interno');\n"
    . "define('APP_URL', " . var_export($appUrl, true) . ");\n\n"
    . "define('UPLOAD_DIR', 'uploads/');\n"
    . "define('MAX_UPLOAD_SIZE', 10 * 1024 * 1024);\n\n"
    . "date_default_timezone_set('America/Sao_Paulo');\n";
if (file_put_contents('/var/www/html/config.php', $config) === false) {
    fwrite(STDERR, "Falha ao gravar config.php\n");
    exit(1);
}
PHP
  docker exec portal-foxdesk chown www-data:www-data /var/www/html/config.php
  docker exec portal-foxdesk chmod 640 /var/www/html/config.php
  docker exec portal-foxdesk mkdir -p /var/www/html/uploads /var/www/html/storage
  docker exec portal-foxdesk chown -R www-data:www-data /var/www/html/uploads /var/www/html/storage

  [[ -f "$CREDENTIALS_FILE" ]] || { : > "$CREDENTIALS_FILE"; chmod 600 "$CREDENTIALS_FILE"; }
  printf 'FoxDesk   | Admin        | login: %-32s | senha: %s\n' "$FOXDESK_ADMIN_EMAIL" "$FOXDESK_ADMIN_PASSWORD" >> "$CREDENTIALS_FILE"
  unset ADMIN_HASH
fi

log "Aplicando padronização pt-BR..."
cat <<'SQL' | docker exec -i portal-foxdesk-db mariadb -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME"
INSERT INTO settings (setting_key, setting_value) VALUES
('app_name','Portal Interno'),
('ticket_prefix','TKT'),
('login_welcome_text','Portal de chamados demonstrativo'),
('app_language','pt-BR'),
('time_format','24'),
('currency','BRL')
ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value);

UPDATE users SET language='pt-BR' WHERE role='admin';
UPDATE statuses SET name='Novo', sort_order=1, color='#0a84ff', is_default=1, is_closed=0 WHERE slug='new';
UPDATE statuses SET name='Em andamento', sort_order=2, color='#30b0c7', is_default=0, is_closed=0 WHERE slug='processing';
UPDATE statuses SET name='Aguardando retorno', sort_order=3, color='#ff9f0a', is_default=0, is_closed=0 WHERE slug='waiting';
UPDATE statuses SET name='Em validação', sort_order=4, color='#5e5ce6', is_default=0, is_closed=0 WHERE slug='testing';
UPDATE statuses SET name='Concluído', sort_order=5, color='#34c759', is_default=0, is_closed=1 WHERE slug='done';
UPDATE priorities SET name='Baixa', sort_order=1, color='#34c759', is_default=0 WHERE slug='low';
UPDATE priorities SET name='Média', sort_order=2, color='#0a84ff', is_default=1 WHERE slug='medium';
UPDATE priorities SET name='Alta', sort_order=3, color='#ff9f0a', is_default=0 WHERE slug='high';
UPDATE priorities SET name='Urgente', sort_order=4, color='#ff3b30', is_default=0 WHERE slug='urgent';
SQL

if [[ -x "$ROOT/scripts/configure-foxdesk-email-ptbr.sh" ]]; then
  PORTAL_ROOT="$ROOT" "$ROOT/scripts/configure-foxdesk-email-ptbr.sh"
else
  die "helper configure-foxdesk-email-ptbr.sh não encontrado/executável."
fi

log "Aplicando logo opcional..."
docker exec portal-foxdesk mkdir -p /var/www/html/uploads
if [[ -f "$ROOT/branding/logo.svg" ]]; then
  docker cp "$ROOT/branding/logo.svg" portal-foxdesk:/var/www/html/uploads/logo.svg >/dev/null
  docker exec portal-foxdesk chown www-data:www-data /var/www/html/uploads/logo.svg
  docker exec portal-foxdesk chmod 640 /var/www/html/uploads/logo.svg
  docker exec portal-foxdesk-db mariadb -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME" -e \
    "INSERT INTO settings (setting_key,setting_value) VALUES ('app_logo','uploads/logo.svg') ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value);" >/dev/null
fi

# Só removemos o instalador depois de config.php existir e o banco estar pronto.
docker exec portal-foxdesk test -s /var/www/html/config.php || die "config.php não foi criado."
docker exec portal-foxdesk rm -f /var/www/html/install.php || true

# Contas da equipe são declaradas em config/portal.json. E-mails em branco são
# aceitos e ficam pendentes até serem preenchidos; depois basta rerodar o helper.
if [[ -x "$ROOT/scripts/configure-foxdesk-users.sh" ]]; then
  PORTAL_ROOT="$ROOT" "$ROOT/scripts/configure-foxdesk-users.sh"
fi

log "Validando aplicação..."
for _ in $(seq 1 30); do
  if curl -fsSL "http://127.0.0.1:${FOXDESK_PORT}/" >/dev/null 2>&1; then
    log "FoxDesk concluído. Prefixo configurado como TKT (IDs no formato TKT-xxxxx)."
    exit 0
  fi
  sleep 2
done

docker logs --tail 120 portal-foxdesk >&2 || true
die "FoxDesk foi configurado, mas não respondeu corretamente ao teste HTTP final."
