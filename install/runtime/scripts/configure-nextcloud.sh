#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
CREDENTIALS_FILE="/root/portal-credenciais-iniciais.txt"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/portal.json}"

[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "ERRO: configuração declarativa não encontrada: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-admin}"
DEPLOY_PROFILE="${DEPLOY_PROFILE:-homologacao}"
NEXTCLOUD_PORT="${NEXTCLOUD_PORT:-8080}"
HOST_IP="${HOST_IP:-127.0.0.1}"
NEXTCLOUD_PUBLIC_URL="${NEXTCLOUD_PUBLIC_URL:-http://${HOST_IP}:${NEXTCLOUD_PORT}}"
FOXDESK_PUBLIC_URL="${FOXDESK_PUBLIC_URL:-http://${HOST_IP}:${FOXDESK_PORT:-8081}}"

log(){ printf '\n[Nextcloud] %s\n' "$*"; }
warn(){ printf '\n[AVISO] %s\n' "$*" >&2; }
occ(){ docker exec -u www-data portal-nextcloud php occ "$@"; }

cfg(){ jq -r "$1" "$CONFIG_FILE"; }

if ! occ status --output=json 2>/dev/null | jq -e '.installed == true' >/dev/null; then
  echo "ERRO: Nextcloud ainda não está instalado." >&2
  exit 1
fi

COMPANY_NAME="$(cfg '.company.name')"
COMPANY_SITE="$(cfg '.company.website')"
COMPANY_SLOGAN="$(cfg '.company.slogan')"
LOGIN_MESSAGE="$(cfg '.company.login_message // .company.slogan')"
PRIMARY_COLOR="$(cfg '.company.primary_color')"
BACKGROUND_COLOR="$(cfg '.company.background_color')"
ALLOW_USER_THEMING="$(cfg '.company.allow_user_theming // true')"
APPLY_BRAND_BACKGROUND="$(cfg '.company.apply_brand_background // true')"
PERSONAL_QUOTA="$(cfg '.security.personal_quota')"
INITIAL_USER_PASSWORD="$(cfg '.security.initial_user_password')"

log "Aplicando configurações gerais..."
occ config:system:set default_phone_region --value="BR" >/dev/null
occ config:system:set default_language --value="pt_BR" >/dev/null
occ config:system:set default_locale --value="pt_BR" >/dev/null
occ config:system:set maintenance_window_start --type=integer --value=3 >/dev/null
occ config:system:set loglevel --type=integer --value=2 >/dev/null
occ config:system:set trusted_domains 0 --value="$HOST_IP" >/dev/null
occ config:system:set trusted_domains 1 --value="localhost" >/dev/null
if [[ "$DEPLOY_PROFILE" == "prod" ]]; then
  occ config:system:set trusted_domains 2 --value="$NEXTCLOUD_DOMAIN" >/dev/null
  occ config:system:set overwrite.cli.url --value="$NEXTCLOUD_PUBLIC_URL" >/dev/null
  occ config:system:set overwriteprotocol --value="https" >/dev/null
  occ config:system:set overwritehost --value="$NEXTCLOUD_DOMAIN" >/dev/null
else
  occ config:system:set overwrite.cli.url --value="$NEXTCLOUD_PUBLIC_URL" >/dev/null
  occ config:system:delete overwriteprotocol >/dev/null 2>&1 || true
  occ config:system:delete overwritehost >/dev/null 2>&1 || true
fi
# Sem conteúdo de demonstração para contas novas.
occ config:system:set skeletondirectory --value="" >/dev/null
# O app nativo "Dashboard" aparece como "Painel" em pt_BR.
# Ele é a porta de entrada de todos os usuários; "portal" não é um app-id.
occ app:enable dashboard >/dev/null 2>&1 || warn "Não foi possível habilitar o Dashboard/Painel nativo."
occ config:system:set defaultapp --value="dashboard" >/dev/null
occ background:cron >/dev/null
occ app:disable firstrunwizard >/dev/null 2>&1 || true

log "Aplicando identidade visual $COMPANY_NAME..."
occ theming:config name "$COMPANY_NAME" >/dev/null
occ theming:config url "$COMPANY_SITE" >/dev/null
occ theming:config slogan "$LOGIN_MESSAGE" >/dev/null
occ theming:config primary_color "$PRIMARY_COLOR" >/dev/null
occ theming:config background_color "$BACKGROUND_COLOR" >/dev/null
if [[ "$ALLOW_USER_THEMING" == "true" ]]; then
  occ theming:config disable-user-theming no >/dev/null 2>&1 || true
  occ config:system:delete enforce_theme >/dev/null 2>&1 || true
else
  occ theming:config disable-user-theming yes >/dev/null 2>&1 || true
fi
if [[ -f "$ROOT/branding/logo.svg" ]]; then
  occ theming:config logo /opt/portal-branding/logo.svg >/dev/null || warn "Não foi possível aplicar o SVG como logo."
  occ theming:config logoheader /opt/portal-branding/logo.svg >/dev/null 2>&1 || true
fi
if [[ "$APPLY_BRAND_BACKGROUND" == "true" && -f "$ROOT/branding/background.png" ]]; then
  occ theming:config background /opt/portal-branding/background.png >/dev/null || warn "Não foi possível aplicar o background."
fi

purge_admin_demo_content(){
  [[ -n "${NEXTCLOUD_ADMIN_PASSWORD:-}" ]] || { warn "Sem senha do admin: conteúdo padrão do admin não pôde ser limpo."; return 0; }
  local root_url="http://127.0.0.1:${NEXTCLOUD_PORT}/remote.php/dav/files/${NEXTCLOUD_ADMIN_USER}/" xml code count=0
  xml="$(curl -fsS -u "${NEXTCLOUD_ADMIN_USER}:${NEXTCLOUD_ADMIN_PASSWORD}" \
    -X PROPFIND -H 'Depth: 1' -H 'Content-Type: application/xml; charset=utf-8' \
    --data '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>' \
    "$root_url" 2>/dev/null || true)"
  [[ -n "$xml" ]] || { warn "Não consegui listar o conteúdo inicial do admin via WebDAV."; return 0; }

  while IFS= read -r href; do
    [[ -n "$href" ]] || continue
    code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${NEXTCLOUD_ADMIN_USER}:${NEXTCLOUD_ADMIN_PASSWORD}" \
      -X DELETE "http://127.0.0.1:${NEXTCLOUD_PORT}${href}" || true)"
    case "$code" in
      204|404) count=$((count+1)) ;;
      *) warn "Não consegui remover item padrão '$href' (HTTP $code)." ;;
    esac
  done < <(WEBDAV_XML="$xml" python3 - "$NEXTCLOUD_ADMIN_USER" <<'PYWEB'
import os, sys, xml.etree.ElementTree as ET
from urllib.parse import unquote, urlparse
admin = sys.argv[1]
raw = os.environ.get('WEBDAV_XML', '')
try:
    root = ET.fromstring(raw)
except ET.ParseError:
    sys.exit(0)
prefix = f"/remote.php/dav/files/{admin}/"
for el in root.iter():
    if el.tag.endswith('href') and el.text:
        parsed = urlparse(el.text)
        path = parsed.path if parsed.scheme else el.text
        decoded = unquote(path)
        if decoded.startswith(prefix) and decoded.rstrip('/') != prefix.rstrip('/'):
            print(path)
PYWEB
  )
  echo "  - conteúdo demonstrativo do admin removido: $count item(ns)"
}

log "Limpando arquivos/pastas padrão do Nextcloud..."
purge_admin_demo_content

prepare_app_store_dir(){
  log "Validando diretório gravável para apps da App Store..."

  # A imagem oficial mantém /var/www/html/apps como somente leitura para apps
  # empacotados e usa /var/www/html/custom_apps para apps baixados da App Store.
  # Em alguns primeiros boots o diretório pai pode nascer com owner root mesmo
  # quando apps_paths declara writable=true. Corrigimos SOMENTE o diretório pai;
  # não fazemos chown recursivo para não tocar no app local portalbackup montado :ro.
  docker exec portal-nextcloud sh -ceu '
    d=/var/www/html/custom_apps
    mkdir -p "$d"
    chown www-data:www-data "$d"
    chmod 0755 "$d"
  '

  if ! docker exec -u www-data portal-nextcloud sh -ceu '
    d=/var/www/html/custom_apps
    test -d "$d"
    test -w "$d"
    f="$d/.portal-write-test-$$"
    : > "$f"
    rm -f "$f"
  '; then
    echo "ERRO: /var/www/html/custom_apps não está gravável por www-data." >&2
    docker exec portal-nextcloud ls -ld /var/www/html/apps /var/www/html/custom_apps >&2 || true
    return 1
  fi

  echo "  - /var/www/html/custom_apps: gravável por www-data"
}

ensure_app(){
  local app="$1" required="${2:-no}" install_output=""
  if occ app:enable "$app" >/dev/null 2>&1; then
    echo "  - $app: habilitado"
    return 0
  fi

  # Não descarte a saída do OCC: ela é essencial para diagnóstico em produção.
  if install_output="$(occ app:install "$app" 2>&1)"; then
    echo "  - $app: instalado"
    return 0
  fi

  [[ -n "$install_output" ]] && printf '  OCC (%s): %s\n' "$app" "$install_output" >&2
  if [[ "$required" == "yes" ]]; then
    echo "ERRO: app obrigatório '$app' não pôde ser instalado." >&2
    return 1
  fi
  warn "App opcional '$app' não pôde ser instalado; siga sem ele e revise depois."
  return 0
}

prepare_app_store_dir

log "Instalando/habilitando apps declarados em config/portal.json..."
while IFS= read -r app; do [[ -n "$app" ]] && ensure_app "$app" yes; done < <(jq -r '.apps.required[]' "$CONFIG_FILE")
while IFS= read -r app; do [[ -n "$app" ]] && ensure_app "$app" no; done < <(jq -r '.apps.optional[]' "$CONFIG_FILE")

log "Aplicando política mínima de senhas..."
PW_MIN="$(cfg '.security.password_policy.min_length // 12')"
PW_COMMON="$(cfg '.security.password_policy.forbid_common_passwords // true')"
PW_BREACHED="$(cfg '.security.password_policy.check_breached_passwords // true')"
PW_HISTORY="$(cfg '.security.password_policy.history_size // 3')"
occ config:app:set password_policy minLength --type=integer --value="$PW_MIN" >/dev/null 2>&1 || true
occ config:app:set password_policy enforceNonCommonPassword --type=boolean --value="$PW_COMMON" >/dev/null 2>&1 || true
occ config:app:set password_policy enforceHaveIBeenPwned --type=boolean --value="$PW_BREACHED" >/dev/null 2>&1 || true
occ config:app:set password_policy historySize --type=integer --value="$PW_HISTORY" >/dev/null 2>&1 || true

log "Criando grupos..."
while IFS= read -r group; do
  [[ -n "$group" ]] || continue
  occ group:add "$group" >/dev/null 2>&1 || true
done < <(jq -r '.groups[]' "$CONFIG_FILE")

occ user:setting "$NEXTCLOUD_ADMIN_USER" settings displayname "Admin" >/dev/null 2>&1 || true
occ user:setting "$NEXTCLOUD_ADMIN_USER" core lang "pt_BR" >/dev/null 2>&1 || true

ensure_user(){
  local row="$1" uid full_name email pass primary group current_email current_name
  uid="$(jq -r '.id' <<<"$row")"
  full_name="$(jq -r '.full_name // .display // .id' <<<"$row")"
  email="$(jq -r '.email // empty' <<<"$row")"
  primary="$(jq -r '.groups[0]' <<<"$row")"

  if occ user:info "$uid" >/dev/null 2>&1; then
    echo "  - $full_name ($uid): já existe; sincronizando perfil"
  else
    pass="$INITIAL_USER_PASSWORD"
    docker exec -e OC_PASS="$pass" -u www-data portal-nextcloud \
      php occ user:add --password-from-env --display-name="$full_name" --group="$primary" "$uid" >/dev/null
    chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true
    printf 'Nextcloud | %-24s | login: %-12s | senha inicial: %s\n' "$full_name" "$uid" "$pass" >> "$CREDENTIALS_FILE"
    echo "  - $full_name ($uid): criado"
  fi

  # Mantém nome completo e e-mail declarados no portal.json como fonte da verdade.
  # O e-mail é aplicado depois da criação para o provisionamento não depender de SMTP
  # já estar configurado e não disparar e-mail de boas-vindas durante a instalação.
  current_name="$(occ user:setting "$uid" settings displayname 2>/dev/null || true)"
  if [[ "$current_name" != "$full_name" ]]; then
    occ user:setting "$uid" settings displayname "$full_name" >/dev/null
  fi
  if [[ -n "$email" ]]; then
    current_email="$(occ user:setting "$uid" settings email 2>/dev/null || true)"
    if [[ "$current_email" != "$email" ]]; then
      occ user:setting "$uid" settings email "$email" >/dev/null
    fi
  fi

  while IFS= read -r group; do
    [[ -n "$group" ]] && occ group:adduser "$group" "$uid" >/dev/null 2>&1 || true
  done < <(jq -r '.groups[]' <<<"$row")
  occ user:setting "$uid" files quota "$PERSONAL_QUOTA" >/dev/null 2>&1 || true
  occ user:setting "$uid" core lang "pt_BR" >/dev/null 2>&1 || true
}

log "Criando usuários e vínculos..."
while IFS= read -r row; do ensure_user "$row"; done < <(jq -c '.users[]' "$CONFIG_FILE")

DB_PREFIX="$(occ config:system:get dbtableprefix 2>/dev/null || true)"
DB_PREFIX="${DB_PREFIX:-oc_}"
nc_sql(){
  docker exec -e MYSQL_PWD="$NC_DB_PASSWORD" portal-nextcloud-db \
    mariadb --batch --skip-column-names -u"$NC_DB_USER" "$NC_DB_NAME" -e "$1"
}
sql_escape(){ printf '%s' "$1" | sed "s/'/''/g"; }

ensure_calendar(){
  local row="$1" uri display owner id group principal uri_sql display_sql
  uri="$(jq -r '.uri' <<<"$row")"
  display="$(jq -r '.name' <<<"$row")"
  owner="$(jq -r '.owner // "admin"' <<<"$row")"
  uri_sql="$(sql_escape "$uri")"; display_sql="$(sql_escape "$display")"
  id="$(nc_sql "SELECT id FROM ${DB_PREFIX}calendars WHERE principaluri='principals/users/${owner}' AND uri='${uri_sql}' LIMIT 1;" | head -n1)"
  if [[ -z "$id" ]]; then
    occ dav:create-calendar "$owner" "$uri" >/dev/null
    id="$(nc_sql "SELECT id FROM ${DB_PREFIX}calendars WHERE principaluri='principals/users/${owner}' AND uri='${uri_sql}' LIMIT 1;" | head -n1)"
  fi
  [[ -n "$id" ]] || { echo "ERRO: não consegui criar/localizar o calendário '$display'." >&2; return 1; }
  nc_sql "UPDATE ${DB_PREFIX}calendars SET displayname='${display_sql}' WHERE id=${id};" >/dev/null
  # Remove apenas shares de grupo deste calendário e recria conforme config.
  nc_sql "DELETE FROM ${DB_PREFIX}dav_shares WHERE resourceid=${id} AND type='calendar' AND principaluri LIKE 'principals/groups/%';" >/dev/null
  while IFS= read -r group; do
    [[ -n "$group" ]] || continue
    principal="principals/groups/${group}"
    nc_sql "INSERT INTO ${DB_PREFIX}dav_shares (principaluri,type,access,resourceid) VALUES ('${principal}','calendar',2,${id});" >/dev/null
  done < <(jq -r '.groups[]' <<<"$row")
  echo "  - $display: criado/validado"
}

log "Criando calendários corporativos..."
while IFS= read -r row; do ensure_calendar "$row"; done < <(jq -c '.calendars[]' "$CONFIG_FILE")

log "Criando agenda pessoal de cada usuário..."
while IFS= read -r uid; do
  [[ -n "$uid" ]] || continue
  personal_row="$(jq -nc --arg uri "pessoal" --arg name "Agenda Pessoal" --arg owner "$uid" \
    '{uri:$uri, name:$name, owner:$owner, groups:[]}')"
  ensure_calendar "$personal_row"
done < <(jq -r '.users[].id' "$CONFIG_FILE")

provision_collectives(){
  [[ -n "${NEXTCLOUD_ADMIN_PASSWORD:-}" ]] || { warn "Sem senha do admin: Collectives não pôde ser provisionado."; return 0; }
  local api="http://127.0.0.1:${NEXTCLOUD_PORT}/ocs/v2.php/apps/collectives/api/v1.0/collectives"
  local data collective_id circle_id created=0 tmpdir pagesdir name owner uid title safe
  name="$(jq -r '.collective.name' "$CONFIG_FILE")"
  owner="$(jq -r '.collective.owner // "admin"' "$CONFIG_FILE")"

  data="$(curl -fsS -u "${NEXTCLOUD_ADMIN_USER}:${NEXTCLOUD_ADMIN_PASSWORD}" -H 'OCS-APIRequest: true' "${api}?format=json" || true)"
  collective_id="$(printf '%s' "$data" | jq -r --arg n "$name" '.ocs.data.collectives[]? | select(.name==$n) | .id' | head -n1)"
  circle_id="$(printf '%s' "$data" | jq -r --arg n "$name" '.ocs.data.collectives[]? | select(.name==$n) | .circleId' | head -n1)"
  if [[ -z "$collective_id" || "$collective_id" == "null" ]]; then
    occ collectives:create "$name" --owner="$owner" >/dev/null
    created=1
    data="$(curl -fsS -u "${NEXTCLOUD_ADMIN_USER}:${NEXTCLOUD_ADMIN_PASSWORD}" -H 'OCS-APIRequest: true' "${api}?format=json")"
    collective_id="$(printf '%s' "$data" | jq -r --arg n "$name" '.ocs.data.collectives[]? | select(.name==$n) | .id' | head -n1)"
    circle_id="$(printf '%s' "$data" | jq -r --arg n "$name" '.ocs.data.collectives[]? | select(.name==$n) | .circleId' | head -n1)"
  fi
  [[ -n "$collective_id" && "$collective_id" != "null" && -n "$circle_id" && "$circle_id" != "null" ]] || { warn "Collective foi criado, mas não consegui resolver seus IDs."; return 1; }

  while IFS= read -r uid; do
    occ circles:members:add "$circle_id" "$uid" --initiator="$owner" >/dev/null 2>&1 || true
  done < <(jq -r '.collective.members[]' "$CONFIG_FILE")

  if [[ "$created" == "1" ]]; then
    tmpdir="$(mktemp -d)"; pagesdir="$tmpdir/portal-collective-pages"; mkdir -p "$pagesdir"
    while IFS= read -r title; do
      safe="$(printf '%s' "$title" | tr '/' '-')"
      case "$title" in
        "Primeiro Acesso")
          cat > "$pagesdir/${safe}.md" <<'EOFMD'
# Primeiro Acesso

## Antes de começar
Cada colaborador deve usar somente a própria conta. A senha inicial é temporária e deve ser trocada no primeiro acesso.

## Passos obrigatórios
1. Entre com seu usuário individual.
2. Troque a senha inicial por uma senha exclusiva, que você não utiliza em outros serviços.
3. Se houver e-mail corporativo disponível, cadastre-o no perfil para convites, notificações e recuperação de conta.
4. Em **Configurações pessoais > Segurança**, configure autenticação em dois fatores (TOTP).
5. Gere os códigos de recuperação do 2FA e guarde-os em local seguro fora do Nextcloud.
6. Em **Aparência e acessibilidade**, escolha tema claro, escuro ou automático conforme sua preferência.

## Por que a senha inicial deve ser trocada?
A senha de implantação existe apenas para colocar as contas em funcionamento. Mantê-la permite que alguém que conheça essa senha tente acessar outra conta e faz uma ação realizada nela ficar associada ao usuário errado.

## Por que usar 2FA?
O segundo fator reduz o risco de acesso indevido caso a senha seja descoberta, reutilizada ou vazada.
EOFMD
          ;;
        "Segurança e Boas Práticas")
          cat > "$pagesdir/${safe}.md" <<'EOFMD'
# Segurança e Boas Práticas

- Não compartilhe sua senha ou códigos de 2FA.
- Não utilize a conta de outro colaborador.
- Não desative 2FA sem necessidade e sem comunicar o administrador.
- Use as Team Folders e calendários conforme sua função; não mova dados corporativos para áreas pessoais sem necessidade.
- Antes de compartilhar um link externo, confira o conteúdo, a necessidade do compartilhamento e a validade do acesso.
- Reporte imediatamente acessos estranhos, perda do telefone usado no 2FA ou comportamento inesperado do portal.
- A base de conhecimento deve registrar procedimentos e soluções validadas para reduzir dependência de conhecimento informal.
EOFMD
          ;;
        *)
          cat > "$pagesdir/${safe}.md" <<EOFMD
# ${title}

## Visão geral
Descreva aqui a finalidade do sistema/processo e o contexto de uso pela $COMPANY_NAME.

## Procedimentos recorrentes
Registre passos de suporte e operação reutilizáveis pela equipe.

## Problemas recorrentes e soluções
Documente sintomas, diagnóstico e solução validada.

## Scripts / SQL
Inclua somente comandos revisados e explique quando podem ser utilizados.

## Links e referências
Adicione documentação, painéis e contatos relacionados.

## Histórico de revisão
Informe data, responsável e motivo das alterações relevantes.
EOFMD
          ;;
      esac
    done < <(jq -r '.collective.pages[]' "$CONFIG_FILE")
    docker cp "$pagesdir" portal-nextcloud:/tmp/portal-collective-pages >/dev/null
    docker exec portal-nextcloud chown -R www-data:www-data /tmp/portal-collective-pages
    if occ list --raw 2>/dev/null | grep -qE '^collectives:import:markdown([[:space:]]|$)'; then
      occ collectives:import:markdown /tmp/portal-collective-pages --collective-id="$collective_id" --user-id="$owner" --parent-id=0 >/dev/null
    else
      warn "Comando de importação Markdown não existe; criando páginas vazias via API."
      while IFS= read -r title; do
        curl -fsS -u "${NEXTCLOUD_ADMIN_USER}:${NEXTCLOUD_ADMIN_PASSWORD}" -H 'OCS-APIRequest: true' \
          -X POST --data-urlencode "title=$title" "${api}/${collective_id}/pages/0?format=json" >/dev/null || warn "Falha ao criar página '$title'."
      done < <(jq -r '.collective.pages[]' "$CONFIG_FILE")
    fi
    docker exec portal-nextcloud rm -rf /tmp/portal-collective-pages >/dev/null 2>&1 || true
    rm -rf "$tmpdir"
  fi
  echo "  - $name: ID $collective_id"
}

log "Provisionando Base de Conhecimento no Collectives..."
provision_collectives

get_folder_id(){
  local name="$1"
  occ groupfolders:list --output=json 2>/dev/null \
    | jq -r --arg n "$name" '.[] | select((.mountPoint // .mount_point // .name) == $n) | .id' | head -n1
}

ensure_team_folder(){
  local row="$1" name quota id group
  name="$(jq -r '.name' <<<"$row")"; quota="$(jq -r '.quota' <<<"$row")"
  id="$(get_folder_id "$name" || true)"
  if [[ -z "$id" || "$id" == "null" ]]; then
    occ groupfolders:create "$name" >/dev/null
    id="$(get_folder_id "$name")"
  fi
  [[ -n "$id" && "$id" != "null" ]] || { echo "ERRO: não consegui resolver ID da Team Folder '$name'." >&2; return 1; }
  occ groupfolders:quota "$id" "$quota" >/dev/null

  while IFS= read -r group; do
    occ groupfolders:group "$id" "$group" --delete >/dev/null 2>&1 || true
  done < <(jq -r '.permissions | keys[]' <<<"$row")

  while IFS= read -r group; do
    mapfile -t perms < <(jq -r --arg g "$group" '.permissions[$g][]' <<<"$row")
    occ groupfolders:group "$id" "$group" "${perms[@]}" >/dev/null
  done < <(jq -r '.permissions | keys[]' <<<"$row")
  echo "  - $name | ID $id | quota $quota"

  if [[ -n "${NEXTCLOUD_ADMIN_PASSWORD:-}" ]]; then
    while IFS= read -r sub; do
      [[ -n "$sub" ]] || continue
      encoded_parent="$(python3 - "$name" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"
      encoded_sub="$(python3 - "$sub" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"
      url="http://127.0.0.1:${NEXTCLOUD_PORT}/remote.php/dav/files/${NEXTCLOUD_ADMIN_USER}/${encoded_parent}/${encoded_sub}"
      code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${NEXTCLOUD_ADMIN_USER}:${NEXTCLOUD_ADMIN_PASSWORD}" -X MKCOL "$url" || true)"
      case "$code" in 201|405) echo "      subpasta: $sub" ;; *) warn "$name/$sub retornou HTTP $code." ;; esac
    done < <(jq -r '.subfolders[]?' <<<"$row")
  fi
}

log "Criando Team Folders, quotas, permissões e subpastas..."
while IFS= read -r row; do ensure_team_folder "$row"; done < <(jq -c '.team_folders[]' "$CONFIG_FILE")

log "Configurando atalhos do menu..."
SITES_JSON="$(jq -c --arg fox "$FOXDESK_PUBLIC_URL" --arg nc "$NEXTCLOUD_PUBLIC_URL" '
  .external_links | to_entries | reduce .[] as $e ({};
    (($e.key + 1) | tostring) as $id |
    .[$id] = {
      id: ($e.key + 1),
      name: $e.value.name,
      url: (if $e.value.url == "@FOXDESK@" then $fox elif $e.value.url == "@NEXTCLOUD@" then $nc else $e.value.url end),
      lang: "", type: "link", device: "", icon: "external.svg",
      groups: ($e.value.groups // []), redirect: true
    }
  )' "$CONFIG_FILE")"
occ config:app:set external sites --value="$SITES_JSON" >/dev/null
LINK_COUNT="$(jq '.external_links | length' "$CONFIG_FILE")"
occ config:app:set external max_site --value="$LINK_COUNT" --type=integer >/dev/null 2>&1 || occ config:app:set external max_site --value="$LINK_COUNT" >/dev/null

log "Executando reparos seguros de pós-instalação..."
occ maintenance:repair >/dev/null || true
occ db:add-missing-indices >/dev/null 2>&1 || true
occ db:add-missing-primary-keys >/dev/null 2>&1 || true

log "Configuração do Nextcloud concluída a partir de config/portal.json."
