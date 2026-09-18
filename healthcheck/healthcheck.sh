#!/usr/bin/env bash
set -uo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/portal.json}"
[[ -f "$CONFIG_FILE" ]] || { echo "ERRO: $CONFIG_FILE não encontrado." >&2; exit 1; }

errors=0
ok(){ printf '  [OK] %s\n' "$*"; }
fail(){ printf '  [FALHA] %s\n' "$*" >&2; errors=$((errors+1)); }
warn(){ printf '  [AVISO] %s\n' "$*"; }

printf '\n=== Portal Interno | Health Check declarativo ===\n'
for c in portal-nextcloud-db portal-redis portal-nextcloud portal-foxdesk-db portal-foxdesk; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]]; then ok "$c em execução"; else fail "$c parado/ausente"; fi
done

if curl -fsS "http://127.0.0.1:${NEXTCLOUD_PORT:-8080}/status.php" | jq -e '.installed == true and .maintenance == false' >/dev/null 2>&1; then
  ok "Nextcloud instalado e fora de manutenção"
else
  fail "Nextcloud não respondeu corretamente"
fi

if docker exec -u www-data portal-nextcloud php occ status >/dev/null 2>&1; then ok "occ funcional"; else fail "occ com erro"; fi
default_app="$(docker exec -u www-data portal-nextcloud php occ config:system:get defaultapp 2>/dev/null | tail -n1 || true)"
if [[ "$default_app" == "dashboard" ]]; then ok "Painel/Dashboard definido como página inicial"; else fail "página inicial divergente (atual='$default_app', esperada='dashboard')"; fi
expected_login_message="$(jq -r '.company.login_message // .company.slogan' "$CONFIG_FILE")"
actual_login_message="$(docker exec -u www-data portal-nextcloud php occ theming:config slogan 2>/dev/null | tail -n1 | sed -E 's/^[[:space:]]*slogan:[[:space:]]*//;s/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
actual_login_message="${actual_login_message#slogan is currently set to }"
if [[ "$actual_login_message" == "$expected_login_message" ]]; then
  ok "mensagem de login: $expected_login_message"
else
  fail "mensagem de login divergente (atual='$actual_login_message', esperada='$expected_login_message')"
fi
if curl -fsS -o /dev/null "http://127.0.0.1:${FOXDESK_PORT:-8081}/"; then ok "FoxDesk responde por HTTP interno"; else fail "FoxDesk sem resposta HTTP"; fi
if docker exec portal-foxdesk test ! -e /var/www/html/install.php; then ok "FoxDesk installer removido"; else warn "install.php ainda existe no FoxDesk"; fi

enabled_apps="$(docker exec -u www-data portal-nextcloud php occ app:list --enabled --output=json 2>/dev/null || echo '{}')"
while IFS= read -r app; do
  if jq -e --arg app "$app" '.enabled | has($app)' <<<"$enabled_apps" >/dev/null 2>&1; then ok "app obrigatório: $app"; else fail "app obrigatório ausente/desabilitado: $app"; fi
done < <(jq -r '.apps.required[]' "$CONFIG_FILE")
while IFS= read -r app; do
  if jq -e --arg app "$app" '.enabled | has($app)' <<<"$enabled_apps" >/dev/null 2>&1; then ok "app opcional: $app"; else warn "app opcional ausente: $app"; fi
done < <(jq -r '.apps.optional[]' "$CONFIG_FILE")

printf '\nUsuários e identidade:\n'
while IFS= read -r row; do
  uid="$(jq -r '.id' <<<"$row")"
  expected_name="$(jq -r '.full_name // .display // .id' <<<"$row")"
  expected_email="$(jq -r '.email // empty' <<<"$row")"
  if ! docker exec -u www-data portal-nextcloud php occ user:info "$uid" >/dev/null 2>&1; then
    fail "usuário ausente: $uid"
    continue
  fi
  actual_name="$(docker exec -u www-data portal-nextcloud php occ user:setting "$uid" settings displayname 2>/dev/null || true)"
  actual_email="$(docker exec -u www-data portal-nextcloud php occ user:setting "$uid" settings email 2>/dev/null || true)"
  [[ "$actual_name" == "$expected_name" ]] && ok "nome: $uid -> $expected_name" || fail "nome divergente: $uid (atual='$actual_name', esperado='$expected_name')"
  if [[ -n "$expected_email" ]]; then
    [[ "$actual_email" == "$expected_email" ]] && ok "e-mail: $uid -> $expected_email" || fail "e-mail divergente: $uid (atual='$actual_email', esperado='$expected_email')"
  else
    warn "e-mail não declarado para $uid (opcional)"
  fi
done < <(jq -c '.users[]' "$CONFIG_FILE")

printf '\nContas FoxDesk da equipe:\n'
fox_sql(){
  docker exec -e MYSQL_PWD="$FOX_DB_PASSWORD" portal-foxdesk-db \
    mariadb --batch --skip-column-names -u"$FOX_DB_USER" "$FOX_DB_NAME" -e "$1" 2>/dev/null
}
while IFS= read -r row; do
  uid="$(jq -r '.id' <<<"$row")"
  full_name="$(jq -r '.full_name // .display // .id' <<<"$row")"
  expected_email="$(jq -r '.email // empty' <<<"$row")"
  expected_role="$(jq -r '.foxdesk_role // "agent"' <<<"$row")"
  if [[ -z "$expected_email" ]]; then
    warn "FoxDesk pendente para $full_name: e-mail não informado"
    continue
  fi
  email_sql="$(printf '%s' "$expected_email" | sed "s/'/''/g")"
  actual_role="$(fox_sql "SELECT role FROM users WHERE LOWER(email)=LOWER('$email_sql') LIMIT 1;" | head -n1 || true)"
  if [[ -z "$actual_role" ]]; then
    fail "conta FoxDesk ausente: $full_name <$expected_email>"
  elif [[ "$actual_role" == "$expected_role" ]]; then
    ok "FoxDesk: $full_name <$expected_email> ($expected_role)"
  else
    fail "perfil FoxDesk divergente para $full_name (atual='$actual_role', esperado='$expected_role')"
  fi
done < <(jq -c '.users[]' "$CONFIG_FILE")

printf '\nE-mails FoxDesk pt-BR:\n'
ptbr_templates="$(fox_sql "SELECT COUNT(*) FROM email_templates WHERE language='pt-BR' AND is_active=1 AND template_key IN ('status_change','new_comment','new_ticket','password_reset','ticket_confirmation','ticket_assignment','recurring_task_assignment','long_timer_alert','welcome_email');" | head -n1 || true)"
if [[ "$ptbr_templates" == "9" ]]; then
  ok "9 templates de e-mail pt-BR ativos"
else
  fail "templates de e-mail pt-BR incompletos (atual='${ptbr_templates:-0}', esperado='9')"
fi
if docker exec portal-foxdesk grep -q 'foxdesk_gl_localize_email_payload' /var/www/html/includes/modules/email/email-renderer.php 2>/dev/null; then
  ok "renderer HTML de e-mail com localização pt-BR"
else
  fail "renderer HTML sem patch de localização pt-BR"
fi
if docker exec portal-foxdesk grep -q "\$copy\['pt-BR'\]" /var/www/html/includes/mailer.php 2>/dev/null; then
  ok "lembretes de prazo do FoxDesk disponíveis em pt-BR"
else
  fail "lembretes de prazo do FoxDesk sem bloco pt-BR"
fi

folders_json="$(docker exec -u www-data portal-nextcloud php occ groupfolders:list --output=json 2>/dev/null || echo '{}')"
while IFS= read -r name; do
  if jq -e --arg n "$name" '.[] | select((.mountPoint // .mount_point // .name) == $n)' <<<"$folders_json" >/dev/null 2>&1; then ok "Team Folder: $name"; else fail "Team Folder ausente: $name"; fi
done < <(jq -r '.team_folders[].name' "$CONFIG_FILE")

DB_PREFIX="$(docker exec -u www-data portal-nextcloud php occ config:system:get dbtableprefix 2>/dev/null || true)"
DB_PREFIX="${DB_PREFIX:-oc_}"
nc_sql(){
  docker exec -e MYSQL_PWD="$NC_DB_PASSWORD" portal-nextcloud-db \
    mariadb --batch --skip-column-names -u"$NC_DB_USER" "$NC_DB_NAME" -e "$1" 2>/dev/null
}
sql_escape(){ printf '%s' "$1" | sed "s/'/''/g"; }

while IFS= read -r row; do
  uri="$(jq -r '.uri' <<<"$row")"; name="$(jq -r '.name' <<<"$row")"; owner="$(jq -r '.owner // "admin"' <<<"$row")"
  uri_sql="$(sql_escape "$uri")"
  id="$(nc_sql "SELECT id FROM ${DB_PREFIX}calendars WHERE principaluri='principals/users/${owner}' AND uri='${uri_sql}' LIMIT 1;" | head -n1)"
  if [[ -z "$id" ]]; then fail "calendário ausente: $name"; continue; else ok "calendário: $name"; fi
  expected="$(jq '.groups|length' <<<"$row")"
  actual=0
  while IFS= read -r g; do
    n="$(nc_sql "SELECT COUNT(*) FROM ${DB_PREFIX}dav_shares WHERE resourceid=${id} AND type='calendar' AND access=2 AND principaluri='principals/groups/${g}';" || echo 0)"
    [[ "$n" =~ ^[0-9]+$ ]] && actual=$((actual+n))
  done < <(jq -r '.groups[]' <<<"$row")
  if [[ "$actual" == "$expected" ]]; then ok "compartilhamentos de $name"; else fail "compartilhamentos incompletos de $name ($actual/$expected)"; fi
done < <(jq -c '.calendars[]' "$CONFIG_FILE")

collective_name="$(jq -r '.collective.name' "$CONFIG_FILE")"
expected_pages="$(jq '.collective.pages|length' "$CONFIG_FILE")"
collective_count="$(nc_sql "SELECT COUNT(*) FROM ${DB_PREFIX}collectives;" || echo 0)"
collective_pages="$(nc_sql "SELECT COUNT(*) FROM ${DB_PREFIX}collectives_pages;" || echo 0)"
if [[ "$collective_count" =~ ^[0-9]+$ && "$collective_count" -ge 1 && "$collective_pages" =~ ^[0-9]+$ && "$collective_pages" -ge "$expected_pages" ]]; then
  ok "Collectives: $collective_name ($collective_pages páginas)"
else
  fail "Collectives/base incompleta (collectives=$collective_count, páginas=$collective_pages, esperado >=$expected_pages)"
fi

if [[ -f /etc/cron.d/portal-nextcloud ]]; then ok "cron Nextcloud instalado"; else fail "cron Nextcloud ausente"; fi
if [[ -f /etc/cron.d/portal-backup ]]; then ok "cron de backup instalado"; else fail "cron de backup ausente"; fi
if systemctl is-active --quiet portal-control.service 2>/dev/null; then ok "serviço de controle backup/restauração ativo"; else fail "portal-control.service inativo"; fi
if [[ -S /run/portal-control/control.sock ]]; then ok "socket restrito de controle disponível no host"; else fail "socket de controle ausente no host"; fi
if docker exec -u www-data portal-nextcloud php -r '
$fp=@stream_socket_client("unix:///run/portal-control/control.sock",$errno,$errstr,2.0);
if($fp===false) exit(1); fwrite($fp,"{\"action\":\"status\"}\n"); stream_set_timeout($fp,2);
$line=fgets($fp); fclose($fp); if($line===false) exit(2); $j=json_decode($line,true);
exit(is_array($j) && (($j["ok"] ?? false) === true) ? 0 : 3);
' >/dev/null 2>&1; then
  ok "Nextcloud consegue operar o canal restrito de Backup/Restauração"
else
  fail "Nextcloud não consegue acessar/responder pelo socket de Backup/Restauração"
fi
if jq -e '.enabled | has("portalbackup")' <<<"$enabled_apps" >/dev/null 2>&1; then ok "app local portalbackup habilitado"; else fail "app local portalbackup ausente/desabilitado"; fi
[[ -d "${RESTORE_INBOX:-/srv/portal-restore-inbox}" ]] && ok "staging de restauração preparado" || fail "staging de restauração ausente"

if [[ "${BACKUP_MODE:-pull}" == "pull" ]]; then
  backup_user="${BACKUP_SFTP_USER:-backupreader}"
  backup_root="${BACKUP_EXPORT_ROOT:-/srv/portal-backup-sftp}"
  if id "$backup_user" >/dev/null 2>&1; then ok "usuário de backup no servidor: $backup_user"; else fail "usuário de backup ausente: $backup_user"; fi
  [[ -d "$backup_root/files/daily" && -d "$backup_root/files/weekly" ]] && ok "exportação SFTP de backup preparada" || fail "diretórios de exportação SFTP ausentes"
  [[ -f /etc/ssh/sshd_config.d/90-portal-backup.conf ]] && ok "restrição SSH/SFTP do backup instalada" || fail "configuração SFTP do backup ausente"
  if /usr/sbin/sshd -t >/dev/null 2>&1; then ok "sshd_config válido"; else fail "sshd_config inválido"; fi
  keyfile="/etc/ssh/authorized_keys/$backup_user"
  if [[ -s "$keyfile" ]]; then ok "chave pública da VM de backup cadastrada"; else warn "VM de backup ainda não pareada; cadastre a chave antes do go-live"; fi
else
  if mountpoint -q /mnt/backup-portal; then
    ok "/mnt/backup-portal é um ponto de montagem"
  elif [[ "${DEPLOY_PROFILE:-homologacao}" == "homologacao" ]]; then
    warn "/mnt/backup-portal ainda não é mount externo (aceitável na homologação)"
  else
    fail "/mnt/backup-portal não é mount separado em perfil prod"
  fi
fi

if [[ "${DEPLOY_PROFILE:-homologacao}" == "prod" ]]; then
  [[ -n "${NEXTCLOUD_DOMAIN:-}" ]] && ok "domínio Nextcloud declarado: $NEXTCLOUD_DOMAIN" || fail "domínio Nextcloud não declarado"
  [[ -n "${FOXDESK_DOMAIN:-}" ]] && ok "domínio FoxDesk declarado: $FOXDESK_DOMAIN" || fail "domínio FoxDesk não declarado"

  # --- Checagem de HTTPS/Caddy (perfil prod) -------------------------------
  # Antes o healthcheck só conferia se o domínio estava DECLARADO no .env,
  # não se o Caddy estava rodando nem se o HTTPS realmente respondia.
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet caddy 2>/dev/null; then
      ok "Caddy ativo (systemd)"
    else
      fail "serviço caddy não está ativo (rode: systemctl status caddy / sudo scripts/configurar-https.sh)"
    fi
  else
    warn "systemctl indisponível; não deu pra checar o serviço caddy."
  fi

  if [[ -f /etc/caddy/Caddyfile ]]; then
    ok "Caddyfile presente em /etc/caddy/Caddyfile"
  else
    fail "Caddyfile ausente; HTTPS não foi configurado (rode: sudo scripts/configurar-https.sh)"
  fi

  for pair in "Nextcloud:${NEXTCLOUD_DOMAIN:-}" "FoxDesk:${FOXDESK_DOMAIN:-}"; do
    label="${pair%%:*}"; domain="${pair#*:}"
    [[ -n "$domain" ]] || continue
    if curl -fsS -o /dev/null --max-time 10 "https://$domain/"; then
      ok "HTTPS de $label responde em https://$domain/"
    else
      fail "HTTPS de $label NÃO respondeu em https://$domain/ (DNS ainda propagando? certificado ainda não emitido? ver: journalctl -u caddy -n 80)"
    fi
  done

  printf '\nURLs públicas esperadas após reverse proxy/TLS:\n  Nextcloud: %s\n  FoxDesk:   %s\n' "$NEXTCLOUD_PUBLIC_URL" "$FOXDESK_PUBLIC_URL"
else
  printf '\nURLs da homologação:\n  Nextcloud: %s\n  FoxDesk:   %s\n' "$NEXTCLOUD_PUBLIC_URL" "$FOXDESK_PUBLIC_URL"
fi

if (( errors > 0 )); then
  printf '\nHealth check terminou com %d falha(s).\n' "$errors" >&2
  exit 1
fi
printf '\nHealth check: estado atual confere com config/portal.json.\n'
