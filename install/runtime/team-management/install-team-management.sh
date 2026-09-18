#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${TEAM_CONFIG_SRC:-$ROOT/team.json}"
CONFIG_DST="/etc/portal-interno/team.json"
CREDS="/root/portal-credenciais-equipe.txt"
log(){ printf '\n[Gestão de Equipe] %s\n' "$*"; }
warn(){ printf '[AVISO] %s\n' "$*" >&2; }
die(){ printf 'ERRO: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "execute com sudo/root."
for x in jq docker openssl systemctl; do command -v "$x" >/dev/null || die "$x não encontrado."; done
[[ -f "$CONFIG_SRC" ]] || die "Configuração de equipe não encontrada em $CONFIG_SRC. Use TEAM_CONFIG_SRC=/caminho/seguro/team.json."
for c in portal-nextcloud portal-foxdesk portal-foxdesk-db; do [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null||true)" == true ]] || die "container $c não está rodando."; done
getent group portalctl >/dev/null || die "grupo portalctl não existe; o controle do Portal Interno não parece instalado."
jq -e '(.users|type=="array") and (.employee_management.allowed_sectors|type=="array")' "$CONFIG_SRC" >/dev/null || die "team.json inválido."
TEMP_PASS="$(jq -r '.employee_management.temporary_password // empty' "$CONFIG_SRC")"
if [[ -n "$TEMP_PASS" && ${#TEMP_PASS} -lt 10 ]]; then die "employee_management.temporary_password deve ter pelo menos 10 caracteres."; fi
if jq -e '.employee_management.allowed_sectors[]?.id == "admin"' "$CONFIG_SRC" >/dev/null; then die "admin não pode aparecer em allowed_sectors."; fi
while IFS= read -r e; do [[ "$e" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "e-mail inválido: $e"; done < <(jq -r '.users[].email // empty | select(length>0)' "$CONFIG_SRC")

log "Instalando configuração protegida..."
install -d -m 0755 /etc/portal-interno
install -o root -g root -m 0600 "$CONFIG_SRC" "$CONFIG_DST"

log "Instalando serviço restrito de gestão de equipe..."
install -d -o root -g root -m 0755 /usr/local/lib/team-management
install -o root -g root -m 0750 "$ROOT/control/team-control.py" /usr/local/lib/team-management/team-control.py
install -o root -g root -m 0644 "$ROOT/control/team-control.service" /etc/systemd/system/team-control.service
systemctl daemon-reload
systemctl enable team-control.service >/dev/null
systemctl restart team-control.service
for _ in $(seq 1 20); do [[ -S /run/portal-control/team.sock ]] && break; sleep .25; done
[[ -S /run/portal-control/team.sock ]] || { systemctl status team-control.service --no-pager >&2 || true; die "socket team.sock não foi criado."; }

occ(){ docker exec -u www-data portal-nextcloud php occ "$@"; }
container_env(){ docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n "s/^$2=//p" | head -n1; }
FOX_DB_NAME="$(container_env portal-foxdesk-db MARIADB_DATABASE)"; FOX_DB_USER="$(container_env portal-foxdesk-db MARIADB_USER)"; FOX_DB_PASSWORD="$(container_env portal-foxdesk-db MARIADB_PASSWORD)"
fox_sql(){ docker exec -e MYSQL_PWD="$FOX_DB_PASSWORD" portal-foxdesk-db mariadb --batch --skip-column-names -u"$FOX_DB_USER" "$FOX_DB_NAME" -e "$1"; }
b64(){ printf '%s' "$1" | base64 -w0; }

log "Sincronizando e-mails dos usuários existentes e criando contas FoxDesk ausentes..."
touch "$CREDS"; chmod 600 "$CREDS"
while IFS= read -r row; do
  uid="$(jq -r '.nextcloud_id' <<<"$row")"; name="$(jq -r '.name // .nextcloud_id' <<<"$row")"; email="$(jq -r '.email // empty' <<<"$row")"
  [[ -n "$email" ]] || { warn "$name: e-mail ainda vazio; ignorado."; continue; }
  if occ user:info "$uid" >/dev/null 2>&1; then
    occ user:setting "$uid" settings email "$email" >/dev/null
  else
    warn "$name ($uid): não existe no Nextcloud; use o novo painel para cadastrar funcionários novos."
    continue
  fi
  eb="$(b64 "$email")"
  fid="$(fox_sql "SELECT id FROM users WHERE (LOWER(CONVERT(email USING utf8mb4)) COLLATE utf8mb4_bin)=(LOWER(CONVERT(FROM_BASE64('${eb}') USING utf8mb4)) COLLATE utf8mb4_bin) LIMIT 1;" | head -n1)"
  if [[ -z "$fid" ]]; then
    pass="$(jq -r '.employee_management.temporary_password // empty' "$CONFIG_DST")"
    [[ -n "$pass" ]] || pass="$(openssl rand -base64 18 | tr -d '=+/\n' | head -c 18)!A7"
    first="${name%% *}"; [[ "$name" == *" "* ]] && last="${name#* }" || last="Usuario"
    hash="$(docker exec -e FOXDESK_USER_PASSWORD="$pass" portal-foxdesk php -r 'echo password_hash(getenv("FOXDESK_USER_PASSWORD"), PASSWORD_DEFAULT);')"
    fox_sql "INSERT INTO users (email,password,first_name,last_name,role,is_active,language,created_at) VALUES (CONVERT(FROM_BASE64('$(b64 "$email")') USING utf8mb4),CONVERT(FROM_BASE64('$(b64 "$hash")') USING utf8mb4),CONVERT(FROM_BASE64('$(b64 "$first")') USING utf8mb4),CONVERT(FROM_BASE64('$(b64 "$last")') USING utf8mb4),'agent',1,'pt-BR',NOW());" >/dev/null
    printf '%s | FoxDesk | %s | login: %s | senha temporária: %s\n' "$(date -Is)" "$name" "$email" "$pass" >> "$CREDS"
    echo "  - $name: e-mail Nextcloud atualizado e FoxDesk criado como agente"
  else
    echo "  - $name: e-mail Nextcloud atualizado; FoxDesk já existia (perfil preservado)"
  fi
done < <(jq -c '.users[]' "$CONFIG_DST")

if [[ "$(jq -r '.theme.apply // false' "$CONFIG_DST")" == true ]]; then
  log "Aplicando identidade visual..."
  primary="$(jq -r '.theme.primary_color // empty' "$CONFIG_DST")"; background="$(jq -r '.theme.background_color // empty' "$CONFIG_DST")"; favicon="$(jq -r '.theme.favicon_source // empty' "$CONFIG_DST")"
  [[ -z "$primary" || "$primary" =~ ^#[0-9A-Fa-f]{6}$ ]] || die "primary_color inválida."
  [[ -z "$background" || "$background" =~ ^#[0-9A-Fa-f]{6}$ ]] || die "background_color inválida."
  [[ -n "$primary" ]] && occ theming:config primary_color "$primary" >/dev/null
  [[ -n "$background" ]] && occ theming:config background_color "$background" >/dev/null
  if [[ -n "$favicon" && -f "$favicon" ]]; then docker cp "$favicon" portal-nextcloud:/tmp/portal-favicon.png >/dev/null; docker exec portal-nextcloud chown www-data:www-data /tmp/portal-favicon.png; occ theming:config favicon /tmp/portal-favicon.png >/dev/null; fi
fi

if [[ "$(jq -r '.smtp.enabled // false' "$CONFIG_DST")" == true ]]; then
  log "Configurando SMTP Nextcloud + FoxDesk..."
  host="$(jq -r '.smtp.host' "$CONFIG_DST")"; port="$(jq -r '.smtp.port' "$CONFIG_DST")"; enc="$(jq -r '.smtp.encryption' "$CONFIG_DST")"; user="$(jq -r '.smtp.username' "$CONFIG_DST")"; from="$(jq -r '.smtp.from_email' "$CONFIG_DST")"; fromname="$(jq -r '.smtp.from_name' "$CONFIG_DST")"
  read -rsp "Senha SMTP de $user: " SMTP_PASSWORD; echo; [[ -n "$SMTP_PASSWORD" ]] || die "senha SMTP vazia."
  occ config:system:set mail_smtpmode --value=smtp >/dev/null; occ config:system:set mail_smtphost --value="$host" >/dev/null; occ config:system:set mail_smtpport --type=integer --value="$port" >/dev/null; occ config:system:set mail_smtpsecure --value="$enc" >/dev/null; occ config:system:set mail_smtpauth --type=boolean --value=true >/dev/null; occ config:system:set mail_smtpauthtype --value=LOGIN >/dev/null; occ config:system:set mail_smtpname --value="$user" >/dev/null; occ config:system:set mail_smtppassword --value="$SMTP_PASSWORD" >/dev/null; occ config:system:set mail_from_address --value="${from%@*}" >/dev/null; occ config:system:set mail_domain --value="${from#*@}" >/dev/null
  fox_sql "INSERT INTO settings (setting_key,setting_value) VALUES ('smtp_host',CONVERT(FROM_BASE64('$(b64 "$host")') USING utf8mb4)),('smtp_port','$port'),('smtp_user',CONVERT(FROM_BASE64('$(b64 "$user")') USING utf8mb4)),('smtp_pass',CONVERT(FROM_BASE64('$(b64 "$SMTP_PASSWORD")') USING utf8mb4)),('smtp_from_email',CONVERT(FROM_BASE64('$(b64 "$from")') USING utf8mb4)),('smtp_from_name',CONVERT(FROM_BASE64('$(b64 "$fromname")') USING utf8mb4)),('smtp_encryption',CONVERT(FROM_BASE64('$(b64 "$enc")') USING utf8mb4)),('email_notifications_enabled','1') ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value);" >/dev/null
  unset SMTP_PASSWORD
fi

log "Instalando app Gestão de Equipe dentro do Nextcloud..."
docker exec portal-nextcloud rm -rf /var/www/html/custom_apps/teammanager
docker cp "$ROOT/nextcloud-app/teammanager" portal-nextcloud:/var/www/html/custom_apps/teammanager
docker exec portal-nextcloud chown -R www-data:www-data /var/www/html/custom_apps/teammanager
occ app:disable teammanager >/dev/null 2>&1 || true
occ app:enable --groups admin --groups gestao teammanager >/dev/null

log "Validando..."
systemctl is-active --quiet team-control.service || die "team-control não está ativo."
occ app:list --enabled | grep -q teammanager || die "app teammanager não ficou habilitado."
echo
printf 'Concluído. O painel "Gestão de Equipe" ficará visível somente para os grupos admin e gestao.\n'
printf 'Novos funcionários: Nextcloud (quota %s) + FoxDesk agente.\n' "$(jq -r '.employee_management.personal_quota // "2 GB"' "$CONFIG_DST")"
printf 'Setores permitidos: %s\n' "$(jq -r '[.employee_management.allowed_sectors[].name] | join(", ")' "$CONFIG_DST")"
printf 'Credenciais temporárias existentes: %s (modo 600).\n' "$CREDS"
printf 'Depois de confirmar tudo, pode apagar a pasta deste instalador de /home/portaladmin.\n'
