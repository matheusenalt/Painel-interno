#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/portal.json}"
CREDENTIALS_FILE="/root/portal-credenciais-iniciais.txt"

[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -f "$CONFIG_FILE" ]] || { echo "ERRO: $CONFIG_FILE não encontrado." >&2; exit 1; }

log(){ printf '\n[FoxDesk usuários] %s\n' "$*"; }
warn(){ printf '[AVISO] %s\n' "$*" >&2; }
die(){ printf 'ERRO: %s\n' "$*" >&2; exit 1; }
sql_escape(){ printf '%s' "$1" | sed "s/'/''/g"; }

command -v jq >/dev/null 2>&1 || die "jq não está instalado."
command -v openssl >/dev/null 2>&1 || die "openssl não está instalado."
[[ "$(docker inspect -f '{{.State.Running}}' portal-foxdesk 2>/dev/null || true)" == "true" ]] || die "container portal-foxdesk não está em execução."
[[ "$(docker inspect -f '{{.State.Running}}' portal-foxdesk-db 2>/dev/null || true)" == "true" ]] || die "container portal-foxdesk-db não está em execução."
docker exec portal-foxdesk test -s /var/www/html/config.php >/dev/null 2>&1 || die "FoxDesk ainda não está instalado/configurado."

fox_sql(){
  docker exec -e MYSQL_PWD="$FOX_DB_PASSWORD" portal-foxdesk-db \
    mariadb --batch --skip-column-names -u"$FOX_DB_USER" "$FOX_DB_NAME" -e "$1"
}

created=0
skipped=0
pending=0

while IFS= read -r row; do
  uid="$(jq -r '.id // empty' <<<"$row")"
  full_name="$(jq -r '.full_name // .display // .id' <<<"$row")"
  email="$(jq -r '.email // empty' <<<"$row")"
  role="$(jq -r '.foxdesk_role // "agent"' <<<"$row")"

  [[ "$role" == "admin" || "$role" == "agent" ]] || die "foxdesk_role inválido para $uid: $role"

  if [[ -z "$email" ]]; then
    warn "$full_name: e-mail ainda não informado; conta FoxDesk ficou pendente."
    pending=$((pending+1))
    continue
  fi
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "e-mail inválido para $uid: $email"

  email_sql="$(sql_escape "$email")"
  exists="$(fox_sql "SELECT COUNT(*) FROM users WHERE LOWER(email)=LOWER('$email_sql');" | head -n1)"
  if [[ "$exists" =~ ^[0-9]+$ && "$exists" -gt 0 ]]; then
    log "$full_name já possui conta em $email; mantendo a conta existente."
    skipped=$((skipped+1))
    continue
  fi

  first_name="${full_name%% *}"
  if [[ "$full_name" == *" "* ]]; then
    last_name="${full_name#* }"
  else
    last_name="Usuario"
  fi

  password="$(openssl rand -hex 18)"
  pass_hash="$(docker exec -e FOXDESK_USER_PASSWORD="$password" portal-foxdesk php -r 'echo password_hash(getenv("FOXDESK_USER_PASSWORD"), PASSWORD_DEFAULT);')"
  [[ -n "$pass_hash" ]] || die "não foi possível gerar hash de senha para $full_name."

  first_sql="$(sql_escape "$first_name")"
  last_sql="$(sql_escape "$last_name")"

  fox_sql "INSERT INTO users (email,password,first_name,last_name,role,is_active,language,created_at) VALUES ('$email_sql','$pass_hash','$first_sql','$last_sql','$role',1,'pt-BR',NOW());" >/dev/null

  [[ -f "$CREDENTIALS_FILE" ]] || : > "$CREDENTIALS_FILE"
  chmod 600 "$CREDENTIALS_FILE"
  printf 'FoxDesk   | %-12s | login: %-36s | senha: %s | perfil: %s\n' "$full_name" "$email" "$password" "$role" >> "$CREDENTIALS_FILE"
  chmod 600 "$CREDENTIALS_FILE"

  log "Conta criada: $full_name ($role). Senha registrada somente em $CREDENTIALS_FILE."
  created=$((created+1))
  unset password pass_hash

done < <(jq -c '.users[]' "$CONFIG_FILE")

printf '\nFoxDesk usuários: criados=%d | já existentes=%d | pendentes sem e-mail=%d\n' "$created" "$skipped" "$pending"
if (( pending > 0 )); then
  printf 'Preencha users[].email em %s e rode novamente:\n  sudo %s/scripts/configure-foxdesk-users.sh\n' "$CONFIG_FILE" "$ROOT"
fi
