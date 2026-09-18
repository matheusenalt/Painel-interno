#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/portal-interno"
CREDENTIALS_FILE="/root/portal-credenciais-iniciais.txt"
CONFIG_FILE="${PORTAL_CONFIG:-$SOURCE_DIR/config/portal.json}"

log(){ printf '\n\033[1;34m[Portal Interno]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_install_artifacts(){
  log "Removendo arquivos usados somente durante a instalação..."

  # Mantém apenas o que é necessário para operação/manutenção do ambiente.
  rm -f \
    "$TARGET_DIR/install-portal.sh" \
    "$TARGET_DIR/reinstalar-homologacao.sh" \
    "$TARGET_DIR/README.md" \
    "$TARGET_DIR/SHA256SUMS" \
    "$TARGET_DIR/validar-config.sh"
  rm -rf "$TARGET_DIR/docs"
  rm -f \
    "$TARGET_DIR/scripts/configure-nextcloud.sh" \
    "$TARGET_DIR/scripts/configure-foxdesk.sh"

  # Remove também o diretório extraído do pacote, com guardas de segurança.
  if [[ "$SOURCE_DIR" != "$TARGET_DIR" && -f "$SOURCE_DIR/install-portal.sh" && -f "$SOURCE_DIR/compose.yaml" ]]; then
    case "$(basename "$SOURCE_DIR")" in
      portal|portal-interno-provisionamento*) rm -rf "$SOURCE_DIR" ;;
    esac
  fi

  log "Limpeza pós-instalação concluída. Arquivos operacionais mantidos em $TARGET_DIR."
}

publish_install_log_to_nextcloud(){
  local report target
  report="$(mktemp /tmp/portal-interno-install-report.XXXXXX)"
  target="/${NEXTCLOUD_ADMIN_USER:-admin}/files/Portal-Instalacao.log"

  {
    printf 'PORTAL INTERNO - LOG DE INSTALACAO (SANITIZADO)\n'
    printf 'Gerado em: %s\n' "$(date -Is)"
    printf 'Versao do provisionamento: v1.17\n'
    printf 'Perfil: %s\n' "${DEPLOY_PROFILE:-desconhecido}"
    printf 'Nextcloud: %s\n' "${NEXTCLOUD_PUBLIC_URL:-desconhecido}"
    printf 'FoxDesk: %s\n' "${FOXDESK_PUBLIC_URL:-desconhecido}"
    printf 'Health check final: %s\n' "$([[ "${HEALTHCHECK_OK:-0}" == "1" ]] && echo OK || echo REVISAR)"
    printf '\nEste arquivo nao contem senhas nem segredos. O log bruto permanece protegido no host em %s (modo 600).\n' "$INSTALL_LOG"
    if [[ -f /root/portal-interno-versoes.txt ]]; then
      printf '\n--- VERSOES / IMAGENS ---\n'
      cat /root/portal-interno-versoes.txt
    fi
    printf '\n--- LOG DA INSTALACAO ---\n'
    # Remove sequencias ANSI e mascara qualquer linha que pareca carregar segredo.
    sed -E \
      -e $'s/\x1B\[[0-9;]*[[:alpha:]]//g' \
      -e '/(senha|password|passwd|secret|token|api[_-]?key|credencial)/I c\[LINHA OCULTA - possível segredo]' \
      -e '/(MYSQL_PASSWORD|MARIADB_PASSWORD|REDIS_PASSWORD|NC_DB_PASSWORD|NC_DB_ROOT_PASSWORD|FOX_DB_PASSWORD|FOX_DB_ROOT_PASSWORD)=/I s/=.*/=[OCULTO]/' \
      "$INSTALL_LOG"
  } > "$report"
  chmod 600 "$report"

  if docker exec -i -u www-data portal-nextcloud php occ files:put - "$target" < "$report" >/dev/null 2>&1; then
    log "Log sanitizado publicado no Nextcloud: Arquivos > Portal-Instalacao.log (usuário admin)."
  else
    warn "Não consegui publicar o log dentro do Nextcloud. O log bruto continua em $INSTALL_LOG."
  fi
  rm -f "$report"
}

[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo ./install-portal.sh"
[[ -f "$CONFIG_FILE" ]] || die "Configuração não encontrada: $CONFIG_FILE"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" && ( "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ) ]] || die "Este pacote requer Ubuntu Server 22.04 ou 24.04. Detectado: ${PRETTY_NAME:-desconhecido}."
else
  die "/etc/os-release não encontrado."
fi

cat <<'BANNER'
============================================================
 Portal Interno Self-Hosted | Provisionamento v1.17
 Ubuntu Server 22.04/24.04 + Docker + Nextcloud + FoxDesk
============================================================
BANNER

INSTALL_LOG="/var/log/portal-interno-install.log"
touch "$INSTALL_LOG"
chmod 600 "$INSTALL_LOG"
exec > >(tee -a "$INSTALL_LOG") 2>&1
log "Log desta execução: $INSTALL_LOG"

CPU_COUNT="$(nproc)"
MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
DISK_AVAIL_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
log "Preflight: ${CPU_COUNT} vCPU | ${MEM_MB} MB RAM | ${DISK_AVAIL_GB} GB livres em /"
(( CPU_COUNT >= 2 )) || warn "Menos de 2 vCPU; a homologação pode ficar bem lenta."
(( MEM_MB >= 3500 )) || warn "Menos de ~4 GB de RAM; instalação/atualização dos apps pode pressionar memória."
(( DISK_AVAIL_GB >= 25 )) || warn "Menos de 25 GB livres; para homologação completa recomendamos ao menos 40 GB."

if [[ -f "$TARGET_DIR/.env" ]]; then
  die "Já existe um ambiente em $TARGET_DIR. Para não sobrescrever dados/segredos, o instalador foi interrompido. Se esta for a VM de homologação, extraia novamente o pacote e use reinstalar-homologacao.sh."
fi

read -r -p "Perfil [homologacao/prod] (padrão: homologacao): " DEPLOY_PROFILE
DEPLOY_PROFILE="${DEPLOY_PROFILE:-homologacao}"
[[ "$DEPLOY_PROFILE" == "homologacao" || "$DEPLOY_PROFILE" == "prod" ]] || die "Perfil deve ser homologacao ou prod."

# Marcador persistente fora de /opt: protege contra reset destrutivo no host errado.
install -d -m 0700 /etc/portal-interno
printf '%s\n' "$DEPLOY_PROFILE" > /etc/portal-interno/environment
chmod 600 /etc/portal-interno/environment

# Coleta do domínio de produção. Feita com sed/regex do bash porque jq só é
# garantido depois da instalação de pacotes-base (mais abaixo), mas o domínio
# precisa ser perguntado antes das senhas.
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }

if [[ "$DEPLOY_PROFILE" == "prod" ]]; then
  PROD_SCHEME_PRE="$(sed -n 's/.*"scheme"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
  PROD_SCHEME_PRE="${PROD_SCHEME_PRE:-https}"
  EXISTING_NC_DOMAIN="$(sed -n 's/.*"nextcloud_domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
  EXISTING_FOX_DOMAIN="$(sed -n 's/.*"foxdesk_domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"

  KEEP_EXISTING_DOMAINS=0
  if valid_domain "$EXISTING_NC_DOMAIN" && valid_domain "$EXISTING_FOX_DOMAIN"; then
    printf '\nDomínios já definidos em config/portal.json:\n  Nextcloud: %s\n  FoxDesk:   %s\n' "$EXISTING_NC_DOMAIN" "$EXISTING_FOX_DOMAIN"
    read -r -p "Manter esses domínios? [S/n]: " keep_domains
    [[ "$keep_domains" =~ ^[nN]$ ]] || KEEP_EXISTING_DOMAINS=1
  fi

  if [[ "$KEEP_EXISTING_DOMAINS" == "1" ]]; then
    NEXTCLOUD_DOMAIN_PRE="$EXISTING_NC_DOMAIN"
    FOXDESK_DOMAIN_PRE="$EXISTING_FOX_DOMAIN"
  else
    log "Perfil de produção: informe o endereço completo do Portal Interno. O Nextcloud usará esse domínio sem prefixo 'cloud'."
    while true; do
      read -r -p "Domínio do Portal Interno / Nextcloud (ex: portal.empresa.exemplo): " PANEL_DOMAIN
      valid_domain "$PANEL_DOMAIN" && break
      warn "'$PANEL_DOMAIN' não parece um domínio válido. Exemplo: portal.empresa.exemplo"
    done

    read -r -p "Subdomínio do FoxDesk (Enter para 'chamados'): " FOX_SUBDOMAIN
    FOX_SUBDOMAIN="${FOX_SUBDOMAIN:-chamados}"

    NEXTCLOUD_DOMAIN_PRE="$PANEL_DOMAIN"
    FOXDESK_DOMAIN_PRE="${FOX_SUBDOMAIN}.${PANEL_DOMAIN}"
    valid_domain "$NEXTCLOUD_DOMAIN_PRE" || die "Domínio inválido: $NEXTCLOUD_DOMAIN_PRE"
    valid_domain "$FOXDESK_DOMAIN_PRE" || die "Domínio inválido: $FOXDESK_DOMAIN_PRE"
  fi

  printf '\nAponte estes registros DNS (tipo A) para o IP público da VPS antes do go-live:\n  %s\n  %s\n' "$NEXTCLOUD_DOMAIN_PRE" "$FOXDESK_DOMAIN_PRE"
  warn "Este instalador configura Nextcloud e FoxDesk para responder por esses domínios (trusted_domains, URL pública). Ele NÃO cria o registro DNS nem o certificado TLS — isso continua sendo feito no seu provedor de DNS + reverse proxy. Ver docs/PRODUCAO.md."
fi

valid_ipv4(){
  local ip="$1" a b c d
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

HOST_IP="$(ip -4 route get 192.0.2.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if ! valid_ipv4 "$HOST_IP"; then
  HOST_IP="$(hostname -I | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$' || true)"
fi
valid_ipv4 "$HOST_IP" || die "Não consegui detectar um IPv4 válido da VM. Confira com: ip a"

while true; do
  read -r -p "IP de acesso da VM (aperte Enter para aceitar o detectado) [$HOST_IP]: " input_ip
  candidate_ip="${input_ip:-$HOST_IP}"
  if valid_ipv4 "$candidate_ip"; then
    HOST_IP="$candidate_ip"
    break
  fi
  warn "'$candidate_ip' não é um IPv4 válido. Exemplo: 192.0.2.10. Para confirmar o detectado, apenas aperte Enter."
done

read_secret(){
  local label="$1" outvar="$2" a b
  while true; do
    read -rsp "$label (mín. 12 caracteres): " a; echo
    [[ ${#a} -ge 12 ]] || { warn "Senha curta demais."; continue; }
    read -rsp "Confirme a senha: " b; echo
    [[ "$a" == "$b" ]] || { warn "As senhas não conferem."; continue; }
    printf -v "$outvar" '%s' "$a"
    break
  done
}

read_secret "Senha do Admin do Nextcloud" NEXTCLOUD_ADMIN_PASSWORD
read_secret "Senha do Admin do FoxDesk" FOXDESK_ADMIN_PASSWORD

# O FoxDesk usa um campo de e-mail como identificador de login. Como a conta
# corporativa ainda não foi fornecida, usamos um identificador local não
# entregável. SMTP/notificações ficam desativados até um e-mail real ser definido.
FOXDESK_ADMIN_EMAIL="admin@exemplo.invalid"

if [[ "$DEPLOY_PROFILE" == "prod" ]]; then
  SUMMARY_NEXTCLOUD="${PROD_SCHEME_PRE:-https}://${NEXTCLOUD_DOMAIN_PRE}"
  SUMMARY_FOXDESK="${PROD_SCHEME_PRE:-https}://${FOXDESK_DOMAIN_PRE}"
else
  SUMMARY_NEXTCLOUD="http://${HOST_IP}:8080"
  SUMMARY_FOXDESK="http://${HOST_IP}:8081"
fi
printf '
Resumo antes do provisionamento:
  Perfil: %s
  IP da máquina: %s
  Nextcloud: %s
  FoxDesk:   %s
  Login Admin FoxDesk: %s
' \
  "$DEPLOY_PROFILE" "$HOST_IP" "$SUMMARY_NEXTCLOUD" "$SUMMARY_FOXDESK" "$FOXDESK_ADMIN_EMAIL"
read -r -p "Continuar com esses dados? [S/n]: " confirm_install
[[ ! "$confirm_install" =~ ^[nN]$ ]] || die "Instalação cancelada para você corrigir os dados."

log "Instalando pacotes-base..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq openssl python3 rsync ufw fail2ban unattended-upgrades cron openssh-server

if [[ "$DEPLOY_PROFILE" == "prod" ]]; then
  log "Gravando domínios de produção em config/portal.json..."
  TMP_CFG="$(mktemp)"
  jq --arg nc "$NEXTCLOUD_DOMAIN_PRE" --arg fx "$FOXDESK_DOMAIN_PRE" \
    '.network.production.nextcloud_domain = $nc | .network.production.foxdesk_domain = $fx' \
    "$CONFIG_FILE" > "$TMP_CFG" && mv "$TMP_CFG" "$CONFIG_FILE"
fi

log "Validando configuração declarativa do portal..."
"$SOURCE_DIR/validar-config.sh" "$DEPLOY_PROFILE"

COMPANY_NAME="$(jq -r '.company.name' "$CONFIG_FILE")"
TZ_CONFIG="$(jq -r '.company.timezone' "$CONFIG_FILE")"
NEXTCLOUD_VERSION="$(jq -r '.versions.nextcloud' "$CONFIG_FILE")"
MARIADB_VERSION="$(jq -r '.versions.mariadb' "$CONFIG_FILE")"
REDIS_VERSION="$(jq -r '.versions.redis' "$CONFIG_FILE")"
FOXDESK_VERSION="$(jq -r '.versions.foxdesk' "$CONFIG_FILE")"
FOXDESK_SHA256="$(jq -r '.versions.foxdesk_sha256 // empty' "$CONFIG_FILE")"
NEXTCLOUD_PORT="$(jq -r '.network.nextcloud_port' "$CONFIG_FILE")"
FOXDESK_PORT="$(jq -r '.network.foxdesk_port' "$CONFIG_FILE")"
PROD_SCHEME="$(jq -r '.network.production.scheme // "https"' "$CONFIG_FILE")"
NEXTCLOUD_DOMAIN="$(jq -r '.network.production.nextcloud_domain // empty' "$CONFIG_FILE")"
FOXDESK_DOMAIN="$(jq -r '.network.production.foxdesk_domain // empty' "$CONFIG_FILE")"
BACKUP_MODE="$(jq -r '.backup.mode // "pull"' "$CONFIG_FILE")"
BACKUP_SFTP_USER="$(jq -r '.backup.sftp_user // "backupreader"' "$CONFIG_FILE")"
BACKUP_EXPORT_ROOT="$(jq -r '.backup.export_root // "/srv/portal-backup-sftp"' "$CONFIG_FILE")"
KEEP_DAILY="$(jq -r '.backup.keep_daily_on_vps // 1' "$CONFIG_FILE")"
KEEP_WEEKLY="$(jq -r '.backup.keep_weekly_on_vps // 0' "$CONFIG_FILE")"
RESTORE_UPLOAD_LIMIT="$(jq -r '.backup.restore_upload_limit // "64G"' "$CONFIG_FILE")"
RESTORE_INBOX="$(jq -r '.backup.restore_inbox // "/srv/portal-restore-inbox"' "$CONFIG_FILE")"
RESTORE_TMP="$(jq -r '.backup.restore_tmp // "/srv/portal-restore-tmp"' "$CONFIG_FILE")"
case "$RESTORE_UPLOAD_LIMIT" in
  *G) RESTORE_UPLOAD_LIMIT_BYTES=$((10#${RESTORE_UPLOAD_LIMIT%G} * 1024 * 1024 * 1024)) ;;
  *M) RESTORE_UPLOAD_LIMIT_BYTES=$((10#${RESTORE_UPLOAD_LIMIT%M} * 1024 * 1024)) ;;
  *) die "restore_upload_limit inválido: $RESTORE_UPLOAD_LIMIT" ;;
esac

log "Configurando fuso horário $TZ_CONFIG..."
timedatectl set-timezone "$TZ_CONFIG"

if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker Engine pelo repositório oficial..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker cron
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  usermod -aG docker "$SUDO_USER" || true
fi

docker compose version >/dev/null || die "Docker Compose plugin não está disponível."

log "Copiando o projeto para $TARGET_DIR..."
mkdir -p "$TARGET_DIR"
rsync -a --delete --exclude '.env' "$SOURCE_DIR/" "$TARGET_DIR/"
chmod 600 "$TARGET_DIR/config/portal.json"
cd "$TARGET_DIR"

log "Preparando grupo restrito do controle de backup/restauração..."
getent group portalctl >/dev/null || groupadd --system portalctl
PORTAL_CONTROL_GID="$(getent group portalctl | cut -d: -f3)"
[[ "$PORTAL_CONTROL_GID" =~ ^[0-9]+$ ]] || die "Não consegui resolver o GID de portalctl."

secret(){ openssl rand -hex 24; }
NC_DB_PASSWORD="$(secret)"
NC_DB_ROOT_PASSWORD="$(secret)"
REDIS_PASSWORD="$(secret)"
FOX_DB_PASSWORD="$(secret)"
FOX_DB_ROOT_PASSWORD="$(secret)"

if [[ "$DEPLOY_PROFILE" == "prod" ]]; then
  BIND_ADDRESS="127.0.0.1"
  NEXTCLOUD_PUBLIC_URL="${PROD_SCHEME}://${NEXTCLOUD_DOMAIN}"
  FOXDESK_PUBLIC_URL="${PROD_SCHEME}://${FOXDESK_DOMAIN}"
else
  BIND_ADDRESS="0.0.0.0"
  NEXTCLOUD_PUBLIC_URL="http://${HOST_IP}:${NEXTCLOUD_PORT}"
  FOXDESK_PUBLIC_URL="http://${HOST_IP}:${FOXDESK_PORT}"
fi

# Buffer pool do MariaDB: escala com a RAM total da máquina. Os valores
# iniciais são conservadores e aumentam automaticamente em hosts com mais memória.
TOTAL_RAM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
if (( TOTAL_RAM_MB >= 15000 )); then
  NC_DB_BUFFER_POOL="1024M"; FOX_DB_BUFFER_POOL="512M"
elif (( TOTAL_RAM_MB >= 7500 )); then
  NC_DB_BUFFER_POOL="512M"; FOX_DB_BUFFER_POOL="256M"
else
  NC_DB_BUFFER_POOL="192M"; FOX_DB_BUFFER_POOL="128M"
fi
log "RAM detectada: ${TOTAL_RAM_MB}MB → innodb-buffer-pool-size Nextcloud=$NC_DB_BUFFER_POOL, FoxDesk=$FOX_DB_BUFFER_POOL (ajustável depois em $TARGET_DIR/.env)."

cat > "$TARGET_DIR/.env" <<ENV
DEPLOY_PROFILE=$DEPLOY_PROFILE
TZ=$TZ_CONFIG
HOST_IP=$HOST_IP
BIND_ADDRESS=$BIND_ADDRESS
NEXTCLOUD_PORT=$NEXTCLOUD_PORT
FOXDESK_PORT=$FOXDESK_PORT
NEXTCLOUD_VERSION=$NEXTCLOUD_VERSION
MARIADB_VERSION=$MARIADB_VERSION
REDIS_VERSION=$REDIS_VERSION
FOXDESK_VERSION=$FOXDESK_VERSION
FOXDESK_SHA256=$FOXDESK_SHA256
NC_DB_BUFFER_POOL=$NC_DB_BUFFER_POOL
FOX_DB_BUFFER_POOL=$FOX_DB_BUFFER_POOL
RELEASE_CHANNEL=production-rc
CONFIG_FILE=$TARGET_DIR/config/portal.json
NEXTCLOUD_DOMAIN=$NEXTCLOUD_DOMAIN
FOXDESK_DOMAIN=$FOXDESK_DOMAIN
NEXTCLOUD_PUBLIC_URL=$NEXTCLOUD_PUBLIC_URL
FOXDESK_PUBLIC_URL=$FOXDESK_PUBLIC_URL
NEXTCLOUD_ADMIN_USER=admin
NC_DB_NAME=nextcloud
NC_DB_USER=nextcloud
NC_DB_PASSWORD=$NC_DB_PASSWORD
NC_DB_ROOT_PASSWORD=$NC_DB_ROOT_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
FOX_DB_NAME=foxdesk
FOX_DB_USER=foxdesk
FOX_DB_PASSWORD=$FOX_DB_PASSWORD
FOX_DB_ROOT_PASSWORD=$FOX_DB_ROOT_PASSWORD
BACKUP_MODE=$BACKUP_MODE
BACKUP_SFTP_USER=$BACKUP_SFTP_USER
BACKUP_EXPORT_ROOT=$BACKUP_EXPORT_ROOT
KEEP_DAILY=$KEEP_DAILY
KEEP_WEEKLY=$KEEP_WEEKLY
RESTORE_UPLOAD_LIMIT=$RESTORE_UPLOAD_LIMIT
RESTORE_UPLOAD_LIMIT_BYTES=$RESTORE_UPLOAD_LIMIT_BYTES
RESTORE_INBOX=$RESTORE_INBOX
RESTORE_TMP=$RESTORE_TMP
PORTAL_CONTROL_GID=$PORTAL_CONTROL_GID
ENV
chmod 600 "$TARGET_DIR/.env"

# Carrega as variáveis recém-gravadas para o próprio processo do instalador.
# Sem isso, set -u interrompe a instalação ao usar NC_DB_NAME/NC_DB_USER no OCC.
set -a
# shellcheck disable=SC1090
source "$TARGET_DIR/.env"
set +a

# A imagem oficial do Nextcloud suporta *_FILE. Guardamos a senha em um
# arquivo root-only e deixamos o entrypoint oficial fazer a instalação inicial.
mkdir -p "$TARGET_DIR/secrets"
printf '%s' "$NEXTCLOUD_ADMIN_PASSWORD" > "$TARGET_DIR/secrets/nextcloud_admin_password"
chmod 700 "$TARGET_DIR/secrets"
chmod 600 "$TARGET_DIR/secrets/nextcloud_admin_password"

: > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"
printf 'PORTAL INTERNO - CREDENCIAIS INICIAIS\nGerado em: %s\n\n' "$(date -Is)" >> "$CREDENTIALS_FILE"
printf 'Nextcloud | Admin        | login: admin        | senha: %s\n' "$NEXTCLOUD_ADMIN_PASSWORD" >> "$CREDENTIALS_FILE"

log "Instalando o serviço restrito de controle de backup/restauração..."
PORTAL_ROOT="$TARGET_DIR" "$TARGET_DIR/scripts/install-backup-control.sh"

log "Baixando/buildando imagens. Na primeira execução isso pode levar alguns minutos..."
docker compose pull nextcloud-db redis foxdesk-db
docker compose build --pull nextcloud foxdesk
docker pull alpine:3.22 >/dev/null

log "Registrando versões/imagens efetivamente usadas nesta instalação..."
VERSIONS_FILE="/root/portal-interno-versoes.txt"
{
  echo "Portal Interno v1.17"
  echo "Gerado em: $(date -Is)"
  echo "Perfil: $DEPLOY_PROFILE"
  echo "Nextcloud: $NEXTCLOUD_VERSION"
  echo "MariaDB: $MARIADB_VERSION"
  echo "Redis: $REDIS_VERSION"
  echo "FoxDesk: $FOXDESK_VERSION"
  echo
  echo "Imagens/Digests resolvidos no teste:"
  nc_id="$(docker image inspect --format '{{.Id}}' "portal-nextcloud:${NEXTCLOUD_VERSION}" 2>/dev/null || true)"
  printf '  %-34s %s\n' "portal-nextcloud:${NEXTCLOUD_VERSION}" "${nc_id:-image id indisponível}"
  for img in "mariadb:${MARIADB_VERSION}" "redis:${REDIS_VERSION}" "alpine:3.22"; do
    digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$img" 2>/dev/null || true)"
    printf '  %-34s %s\n' "$img" "${digest:-digest indisponível}"
  done
  fox_id="$(docker image inspect --format '{{.Id}}' portal-foxdesk 2>/dev/null || true)"
  echo "  FoxDesk build local: ${fox_id:-indisponível}"
} > "$VERSIONS_FILE"
chmod 600 "$VERSIONS_FILE"

log "Subindo primeiro bancos e Redis..."
docker compose up -d nextcloud-db redis foxdesk-db

wait_healthy(){
  local container="$1" label="$2" attempts="${3:-30}"
  for _ in $(seq 1 "$attempts"); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    [[ "$status" == "healthy" || "$status" == "running" ]] && return 0
    sleep 2
  done
  warn "$label não ficou saudável. Últimos logs:"
  docker logs --tail 80 "$container" 2>&1 || true
  if [[ "$container" == "portal-redis" ]]; then
    warn "Resultado do healthcheck do Redis:"
    docker inspect -f '{{range .State.Health.Log}}{{println .Output}}{{end}}' "$container" 2>/dev/null | tail -20 || true
  fi
  return 1
}

wait_healthy portal-nextcloud-db "Banco do Nextcloud" 45 || die "Banco do Nextcloud falhou."
wait_healthy portal-redis "Redis" 30 || die "Redis falhou. Rode: docker logs portal-redis"
wait_healthy portal-foxdesk-db "Banco do FoxDesk" 45 || die "Banco do FoxDesk falhou."

log "Infraestrutura saudável. Subindo Nextcloud e FoxDesk..."
docker compose up -d nextcloud foxdesk

log "Aguardando a instalação automática do Nextcloud pelo entrypoint oficial..."
NC_READY=0
for _ in $(seq 1 120); do
  status_json="$(curl -fsS "http://127.0.0.1:${NEXTCLOUD_PORT}/status.php" 2>/dev/null || true)"
  if [[ -n "$status_json" ]] && printf '%s' "$status_json" | jq -e '.installed == true' >/dev/null 2>&1; then
    NC_READY=1
    break
  fi

  nc_state="$(docker inspect -f '{{.State.Status}}' portal-nextcloud 2>/dev/null || true)"
  if [[ "$nc_state" == "exited" || "$nc_state" == "dead" ]]; then
    warn "O container do Nextcloud parou durante a instalação. Últimos logs:"
    docker logs --tail 120 portal-nextcloud 2>&1 || true
    die "Nextcloud não concluiu a instalação automática."
  fi
  sleep 2
done

if [[ "$NC_READY" != "1" ]]; then
  warn "Nextcloud não ficou instalado dentro do tempo esperado. Últimos logs:"
  docker logs --tail 160 portal-nextcloud 2>&1 || true
  die "Nextcloud não concluiu a instalação automática."
fi

log "Nextcloud instalado com sucesso."

log "Provisionando Nextcloud: usuários, grupos, pastas, apps e branding..."
NEXTCLOUD_ADMIN_PASSWORD="$NEXTCLOUD_ADMIN_PASSWORD" PORTAL_ROOT="$TARGET_DIR" \
  "$TARGET_DIR/scripts/configure-nextcloud.sh"

log "Habilitando app administrativo local de Backup e Restauração..."
docker exec -u www-data portal-nextcloud php occ app:enable portalbackup >/dev/null || die "Não foi possível habilitar o app local portalbackup."

log "Validando acesso do Nextcloud ao serviço restrito de backup/restauração..."
if ! docker exec -u www-data portal-nextcloud php -r '
$fp=@stream_socket_client("unix:///run/portal-control/control.sock",$errno,$errstr,2.0);
if($fp===false){fwrite(STDERR,"connect: $errno $errstr\n"); exit(1);}
fwrite($fp,"{\"action\":\"status\"}\n"); stream_set_timeout($fp,2);
$line=fgets($fp); fclose($fp);
if($line===false){fwrite(STDERR,"sem resposta\n"); exit(2);}
$j=json_decode($line,true); exit(is_array($j) && (($j["ok"] ?? false) === true) ? 0 : 3);
'; then
  warn "O Nextcloud não conseguiu acessar o socket de controle. Diagnóstico:"
  systemctl status portal-control.service --no-pager 2>&1 || true
  docker exec portal-nextcloud sh -c 'id www-data; ls -ld /run/portal-control; ls -l /run/portal-control/control.sock 2>/dev/null || true' 2>&1 || true
  die "Canal seguro de Backup e Restauração indisponível; instalação interrompida antes de ser considerada pronta."
fi
log "Canal seguro de Backup e Restauração validado pelo próprio Nextcloud."

log "Provisionando FoxDesk..."
FOXDESK_ADMIN_PASSWORD="$FOXDESK_ADMIN_PASSWORD" \
FOXDESK_ADMIN_EMAIL="$FOXDESK_ADMIN_EMAIL" \
PORTAL_ROOT="$TARGET_DIR" \
  "$TARGET_DIR/scripts/configure-foxdesk.sh"

log "Instalando rotinas agendadas..."
install -m 0644 "$TARGET_DIR/cron/portal-nextcloud" /etc/cron.d/portal-nextcloud
install -m 0644 "$TARGET_DIR/cron/portal-foxdesk" /etc/cron.d/portal-foxdesk
install -m 0644 "$TARGET_DIR/cron/portal-backup" /etc/cron.d/portal-backup
systemctl restart cron

if [[ "$BACKUP_MODE" == "pull" ]]; then
  log "Preparando exportação de backup via SFTP somente leitura..."
  PORTAL_ROOT="$TARGET_DIR" "$TARGET_DIR/scripts/configure-backup-server.sh"
else
  mkdir -p /mnt/backup-portal
  chmod 700 /mnt/backup-portal
fi

log "Aplicando hardening básico do host sem mexer na autenticação SSH..."
if command -v ufw >/dev/null; then
  # Preserva a(s) porta(s) SSH realmente configurada(s) antes de ativar o UFW.
  # Isso evita derrubar a sessão quando o SSH usa porta customizada (ex.: uma porta SSH customizada).
  mapfile -t SSH_PORTS < <(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un)
  (( ${#SSH_PORTS[@]} > 0 )) || SSH_PORTS=(22)
  for ssh_port in "${SSH_PORTS[@]}"; do
    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || die "Não consegui liberar a porta SSH ${ssh_port}/tcp no UFW."
  done
  # Em homologação, expõe 8080/8081 apenas para teste na LAN. Em produção, os containers ficam em loopback e devem ser publicados só por HTTPS/reverse proxy.
  if [[ "$DEPLOY_PROFILE" == "homologacao" ]]; then
    ufw allow 8080/tcp >/dev/null
    ufw allow 8081/tcp >/dev/null
  fi
  ufw --force enable >/dev/null || true
fi

cat > /etc/fail2ban/jail.d/portal-ssh.conf <<'JAIL'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
systemctl enable --now fail2ban >/dev/null 2>&1 || warn "Fail2ban não iniciou; revise depois."

# Atualizações automáticas somente de segurança do Ubuntu; apps continuam sob atualização controlada.
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

log "SMTP/e-mail não configurado nesta implantação; notificações por e-mail permanecem desativadas."

if [[ "$DEPLOY_PROFILE" == "prod" ]]; then
  printf '\n'
  read -r -p "Configurar HTTPS agora (DNS de $NEXTCLOUD_DOMAIN e $FOXDESK_DOMAIN já apontando para esta VPS)? [S/n]: " https_now
  if [[ ! "$https_now" =~ ^[nN]$ ]]; then
    log "Configurando reverse proxy e certificado TLS..."
    if PORTAL_ROOT="$TARGET_DIR" "$TARGET_DIR/scripts/configurar-https.sh"; then
      HTTPS_CONFIGURED=1
    else
      HTTPS_CONFIGURED=0
      warn "Configuração de HTTPS não concluiu. Confira o DNS e rode depois: sudo $TARGET_DIR/scripts/configurar-https.sh"
    fi
  else
    HTTPS_CONFIGURED=0
    warn "HTTPS ficou pendente. Depois rode: sudo $TARGET_DIR/scripts/configurar-https.sh"
  fi
fi

unset NEXTCLOUD_ADMIN_PASSWORD FOXDESK_ADMIN_PASSWORD NC_DB_PASSWORD NC_DB_ROOT_PASSWORD REDIS_PASSWORD FOX_DB_PASSWORD FOX_DB_ROOT_PASSWORD

log "Validação final..."
if PORTAL_ROOT="$TARGET_DIR" "$TARGET_DIR/scripts/healthcheck.sh"; then
  HEALTHCHECK_OK=1
else
  HEALTHCHECK_OK=0
  warn "A instalação terminou, mas o health check encontrou ponto(s) para revisar. Os arquivos de instalação serão mantidos para diagnóstico."
fi

if [[ "$HEALTHCHECK_OK" == "1" ]]; then
  cleanup_install_artifacts
fi

if [[ "$DEPLOY_PROFILE" == "prod" ]]; then
  ACCESS_NEXTCLOUD="$NEXTCLOUD_PUBLIC_URL (backend interno em 127.0.0.1:$NEXTCLOUD_PORT)"
  ACCESS_FOXDESK="$FOXDESK_PUBLIC_URL (backend interno em 127.0.0.1:$FOXDESK_PORT)"
  if [[ "${HTTPS_CONFIGURED:-0}" == "1" ]]; then
    PROFILE_NOTE="Perfil de produção com HTTPS já configurado via Caddy em $NEXTCLOUD_DOMAIN e $FOXDESK_DOMAIN. Valide backup/restore e siga operacao/CHECKLIST-GO-LIVE.md antes do go-live."
  else
    PROFILE_NOTE="Perfil de produção preparado com os domínios declarados em config/portal.json. Falta: (1) apontar o DNS (A) de $NEXTCLOUD_DOMAIN e $FOXDESK_DOMAIN para o IP desta VPS, se ainda não apontou, e (2) rodar 'sudo $TARGET_DIR/scripts/configurar-https.sh'. Depois disso, valide backup/restore."
  fi
else
  ACCESS_NEXTCLOUD="$NEXTCLOUD_PUBLIC_URL"
  ACCESS_FOXDESK="$FOXDESK_PUBLIC_URL"
  PROFILE_NOTE="Homologação: mesma pilha e configuração funcional planejada para produção; a diferença principal é o acesso HTTP pela LAN, sem domínio/TLS."
fi

cat <<EOF

============================================================
 INSTALAÇÃO CONCLUÍDA — PORTAL INTERNO v1.17
============================================================
 Nextcloud: $ACCESS_NEXTCLOUD
 FoxDesk:   $ACCESS_FOXDESK

 Credenciais iniciais: $CREDENTIALS_FILE
 Manifesto de versões: /root/portal-interno-versoes.txt
 Projeto operacional em: $TARGET_DIR
 Configuração aprovada:  $TARGET_DIR/config/portal.json
 Backup: modo $BACKUP_MODE | export: ${BACKUP_EXPORT_ROOT:-/mnt/backup-portal}

 Backup/Restauração no Nextcloud: menu "Backup e Restauração" (somente admin)
 Restauração externa: upload manual do .tar.gz; .sha256 opcional/recomendado

 Próximas validações recomendadas:
   sudo $TARGET_DIR/scripts/backup.sh
   sudo $TARGET_DIR/scripts/healthcheck.sh
   sudo $TARGET_DIR/scripts/auditar-seguranca.sh

 Backup pull:
   Usuário remoto: $BACKUP_SFTP_USER (SFTP read-only, sem shell/senha)
   Autorizar VM:    sudo $TARGET_DIR/scripts/configurar-chave-backup.sh /caminho/CHAVE_PUBLICA_DA_VM.pub

 Material de operação/treinamento:
   $TARGET_DIR/operacao/TREINAMENTO-USUARIOS.md
   $TARGET_DIR/operacao/CHECKLIST-GO-LIVE.md

 Limpeza: instaladores/testes foram removidos automaticamente após health check OK.

 $PROFILE_NOTE
============================================================
EOF

# Publica uma copia sanitizada do log somente depois da mensagem final, para
# que o arquivo dentro do Nextcloud represente a instalacao completa.
publish_install_log_to_nextcloud
