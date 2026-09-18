#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ "${PORTAL_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>/run/portal-interno-maintenance.lock
  flock -n 9 || { echo "ERRO: outra operação de backup/restauração está em andamento." >&2; exit 75; }
fi

BACKUP_MODE="${BACKUP_MODE:-pull}"
BACKUP_SFTP_USER="${BACKUP_SFTP_USER:-backupreader}"
BACKUP_EXPORT_ROOT="${BACKUP_EXPORT_ROOT:-/srv/portal-backup-sftp}"
if [[ -n "${BACKUP_DEST:-}" ]]; then DEST="$BACKUP_DEST"; elif [[ "$BACKUP_MODE" == "pull" ]]; then DEST="$BACKUP_EXPORT_ROOT/files"; else DEST="/mnt/backup-portal"; fi
KEEP_DAILY="${KEEP_DAILY:-1}"
KEEP_WEEKLY="${KEEP_WEEKLY:-0}"
log(){ printf '[backup] %s\n' "$*"; }
cleanup_nc(){ docker exec -u www-data portal-nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || true; }
cleanup_fox(){ docker start portal-foxdesk >/dev/null 2>&1 || true; }

if [[ "$BACKUP_MODE" == "pull" ]]; then
  [[ "$DEST" == "$BACKUP_EXPORT_ROOT/files" ]] || { echo "ERRO: em modo pull, BACKUP_DEST deve ser $BACKUP_EXPORT_ROOT/files." >&2; exit 1; }
  id "$BACKUP_SFTP_USER" >/dev/null 2>&1 || { echo "ERRO: usuário SFTP $BACKUP_SFTP_USER não existe. Rode configure-backup-server.sh." >&2; exit 1; }
  install -d -o root -g "$BACKUP_SFTP_USER" -m 0750 "$DEST" "$DEST/daily" "$DEST/weekly"
else
  mkdir -p "$DEST/daily" "$DEST/weekly"; chmod 700 "$DEST" "$DEST/daily" "$DEST/weekly" 2>/dev/null || true
  if ! mountpoint -q "$DEST"; then [[ "${DEPLOY_PROFILE:-homologacao}" == "prod" ]] && { echo "ERRO: $DEST não é mount separado. Backup abortado." >&2; exit 1; }; log "AVISO: $DEST não é mount separado; permitido somente em homologação."; fi
fi

stamp="$(date '+%Y%m%d-%H%M%S')"; stage="$DEST/.stage-$stamp"; archive="$DEST/daily/portal-$stamp.tar.gz"; archive_tmp="$DEST/daily/.portal-$stamp.tar.gz.tmp"
mkdir -m 0700 -p "$stage"
trap 'cleanup_nc; cleanup_fox; rm -rf "$stage" "$archive_tmp"' EXIT

log "Ativando manutenção do Nextcloud..."; docker exec -u www-data portal-nextcloud php occ maintenance:mode --on >/dev/null
log "Parando interface do FoxDesk por alguns segundos para snapshot consistente..."; docker stop portal-foxdesk >/dev/null
log "Gerando dumps dos bancos..."
docker exec portal-nextcloud-db mariadb-dump --single-transaction --quick --routines --triggers -u"$NC_DB_USER" -p"$NC_DB_PASSWORD" "$NC_DB_NAME" > "$stage/nextcloud.sql"
docker exec portal-foxdesk-db mariadb-dump --single-transaction --quick --routines --triggers -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME" > "$stage/foxdesk.sql"
log "Copiando volumes de aplicação..."
docker run --rm -v portal-nextcloud-app:/volume:ro -v "$stage:/backup" alpine:3.22 tar -cf /backup/nextcloud-volume.tar -C /volume .
docker run --rm -v portal-foxdesk-app:/volume:ro -v "$stage:/backup" alpine:3.22 tar -cf /backup/foxdesk-volume.tar -C /volume .
log "Salvando configuração operacional..."
config_items=(compose.yaml .env scripts foxdesk branding config control nextcloud-apps nextcloud cron team-management)
existing_items=()
for item in "${config_items[@]}"; do [[ -e "$ROOT/$item" ]] && existing_items+=("$item"); done
tar -czf "$stage/portal-config.tar.gz" -C "$ROOT" "${existing_items[@]}"
if [[ -f /etc/portal-interno/environment || -f /etc/portal-interno/team.json ]]; then
  log "Salvando configuração protegida do host para recuperação de desastre..."
  host_stage="$stage/host-config"
  install -d -m 0700 "$host_stage/etc/portal-interno"
  [[ -f /etc/portal-interno/environment ]] && install -m 0600 /etc/portal-interno/environment "$host_stage/etc/portal-interno/environment"
  [[ -f /etc/portal-interno/team.json ]] && install -m 0600 /etc/portal-interno/team.json "$host_stage/etc/portal-interno/team.json"
  tar -czf "$stage/host-config.tar.gz" -C "$host_stage" etc
  rm -rf "$host_stage"
fi
( cd "$stage" && files=(nextcloud.sql foxdesk.sql nextcloud-volume.tar foxdesk-volume.tar portal-config.tar.gz); [[ -f host-config.tar.gz ]] && files+=(host-config.tar.gz); sha256sum "${files[@]}" > manifest.sha256 )
chmod 600 "$stage"/*
cleanup_fox; cleanup_nc

log "Gerando arquivo final..."
tar -I 'gzip -3' -cf "$archive_tmp" -C "$stage" .
tar -tzf "$archive_tmp" >/dev/null
mv -f "$archive_tmp" "$archive"
if [[ "$BACKUP_MODE" == "pull" ]]; then chown root:"$BACKUP_SFTP_USER" "$archive"; chmod 0640 "$archive"; else chmod 0600 "$archive"; fi
( cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256" )
if [[ "$BACKUP_MODE" == "pull" ]]; then chown root:"$BACKUP_SFTP_USER" "$archive.sha256"; chmod 0640 "$archive.sha256"; else chmod 0600 "$archive.sha256"; fi
log "Integridade local: arquivo gzip/tar legível + SHA-256 externo + manifest interno"
# Por padrão a VPS mantém somente o snapshot diário mais recente.
# KEEP_WEEKLY=0 evita duplicar retenção na VPS; o repositório externo promove
# o snapshot de domingo para a retenção semanal no HD. O bloco abaixo fica
# disponível apenas para instalações que optarem explicitamente por semanais na VPS.
if (( KEEP_WEEKLY > 0 )) && [[ "$(date +%u)" == "7" ]]; then
  weekly="$DEST/weekly/portal-weekly-$stamp.tar.gz"
  if ln "$archive" "$weekly" 2>/dev/null; then
    if [[ "$BACKUP_MODE" == "pull" ]]; then chown root:"$BACKUP_SFTP_USER" "$weekly"; chmod 0640 "$weekly"; fi
    ( cd "$(dirname "$weekly")" && sha256sum "$(basename "$weekly")" > "$(basename "$weekly").sha256" )
    if [[ "$BACKUP_MODE" == "pull" ]]; then chown root:"$BACKUP_SFTP_USER" "$weekly.sha256"; chmod 0640 "$weekly.sha256"; else chmod 0600 "$weekly.sha256"; fi
    log "Snapshot semanal criado por hardlink: $weekly"
  else
    log "AVISO: filesystem não permitiu hardlink semanal; não será criada uma segunda cópia na VPS."
  fi
fi
rotate(){ local dir="$1" pattern="$2" keep="$3"; mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%p\n' | sort -r); if (( ${#files[@]} > keep )); then for ((i=keep;i<${#files[@]};i++)); do rm -f -- "${files[$i]}" "${files[$i]}.sha256"; log "Retenção removeu: ${files[$i]}"; done; fi; }
rotate "$DEST/daily" 'portal-*.tar.gz' "$KEEP_DAILY"; rotate "$DEST/weekly" 'portal-weekly-*.tar.gz' "$KEEP_WEEKLY"
rm -rf "$stage"; trap - EXIT; log "Concluído: $archive"
