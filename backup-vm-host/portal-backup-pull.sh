#!/usr/bin/env bash
# Coleta pull dos snapshots da VPS via SFTP somente leitura e grava no HD externo.
set -Eeuo pipefail

CONF="/etc/portal-backup/backup.env"
[[ -f "$CONF" ]] || { echo "ERRO: $CONF não encontrado. Rode install-vm-linux.sh primeiro." >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

VPS_HOST="${VPS_HOST:?defina VPS_HOST em $CONF}"
VPS_PORT="${VPS_PORT:-22}"
VPS_USER="${VPS_USER:-backupreader}"
# Caminho visto DENTRO do chroot SFTP. Na VPS real corresponde a /srv/portal-backup-sftp/files.
REMOTE_ROOT="${REMOTE_ROOT:-/files}"
LOCAL_MOUNT="${LOCAL_MOUNT:-/mnt/portal-backups}"
KEEP_DAILY_LOCAL="${KEEP_DAILY_LOCAL:-7}"
KEEP_WEEKLY_LOCAL="${KEEP_WEEKLY_LOCAL:-4}"
IDENTITY="$HOME/.ssh/id_ed25519"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
LOG="/var/log/portal-backup-pull.log"
STATUS_FILE=""
new_downloads=0
validated=0
rejected=0
remote_tar_total=0
status_written=0

ts(){ date -Is; }
log(){ printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG"; }
write_status(){
  local status="$1"
  [[ -n "$STATUS_FILE" ]] || return 0
  printf '{"status":"%s","last_attempt":"%s","last_success":%s,"new_downloads":%d,"validated":%d,"rejected":%d,"remote_archives":%d}\n' \
    "$status" "$(ts)" "$([[ "$status" == "ok" ]] && printf '"%s"' "$(ts)" || printf 'null')" \
    "$new_downloads" "$validated" "$rejected" "$remote_tar_total" > "$STATUS_FILE"
  status_written=1
}
fail(){ log "ERRO: $*"; write_status failed || true; exit 1; }
on_exit(){
  local rc=$?
  if (( rc != 0 )) && [[ "$status_written" != "1" && -n "$STATUS_FILE" ]]; then
    write_status failed || true
  fi
}
trap on_exit EXIT

[[ -f "$IDENTITY" ]] || fail "Chave privada não encontrada em $IDENTITY."
[[ -f "$KNOWN_HOSTS" ]] || fail "known_hosts não encontrado em $KNOWN_HOSTS."
# Dispara x-systemd.automount e exige o filesystem real. Um autofs vazio não vale como HD montado.
ls -la "$LOCAL_MOUNT/" >/dev/null 2>&1 || true
fstype="$(findmnt -T "$LOCAL_MOUNT" -n -o FSTYPE 2>/dev/null || true)"
[[ -n "$fstype" && "$fstype" != "autofs" ]] || fail "$LOCAL_MOUNT ainda não montou o filesystem real (fstype=${fstype:-vazio})."
[[ -w "$LOCAL_MOUNT" ]] || fail "$LOCAL_MOUNT não tem permissão de escrita para $(whoami)."

mkdir -p "$LOCAL_MOUNT"/daily "$LOCAL_MOUNT"/weekly "$LOCAL_MOUNT"/logs
STATUS_FILE="$LOCAL_MOUNT/logs/last-run.json"

sftp_batch(){
  sftp -q -o BatchMode=yes -o IdentityFile="$IDENTITY" -o UserKnownHostsFile="$KNOWN_HOSTS" \
       -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
       -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
       -P "$VPS_PORT" -b - "${VPS_USER}@${VPS_HOST}"
}

remote_dir(){
  local kind="$1" root="${REMOTE_ROOT%/}"
  printf '%s/%s' "$root" "$kind"
}

valid_remote_name(){
  local kind="$1" fname="$2"
  if [[ "$kind" == "daily" ]]; then
    [[ "$fname" =~ ^portal-[0-9]{8}-[0-9]{6}\.tar\.gz(\.sha256)?$ ]]
  else
    [[ "$fname" =~ ^portal-weekly-[0-9]{8}-[0-9]{6}\.tar\.gz(\.sha256)?$ ]]
  fi
}

log "Iniciando coleta pull de ${VPS_USER}@${VPS_HOST}:${VPS_PORT}; raiz SFTP de backups: $REMOTE_ROOT"

# Guarda os snapshots remotos para, no fim, exigir que todos tenham cópia local validada.
declare -a remote_archives=()
for kind in daily weekly; do
  rdir="$(remote_dir "$kind")"
  log "Listando $rdir..."
  if ! list_output="$(printf 'ls -1 %s\n' "$rdir" | sftp_batch 2>>"$LOG")"; then
    fail "não consegui listar $rdir via SFTP. A execução NÃO será marcada como sucesso."
  fi

  mapfile -t remote_list < <(printf '%s\n' "$list_output" | grep -E '\.tar\.gz(\.sha256)?$' || true)
  if (( ${#remote_list[@]} == 0 )); then
    log "AVISO: nenhum snapshot encontrado em $rdir."
    continue
  fi

  for raw in "${remote_list[@]}"; do
    fname="$(basename "$raw")"
    valid_remote_name "$kind" "$fname" || { log "IGNORANDO nome remoto inesperado: $kind/$fname"; continue; }
    [[ "$fname" == *.tar.gz ]] && { remote_archives+=("$kind|$fname"); remote_tar_total=$((remote_tar_total + 1)); }

    local_path="$LOCAL_MOUNT/$kind/$fname"
    [[ -f "$local_path" ]] && continue
    tmp_path="$LOCAL_MOUNT/$kind/.tmp-${fname}.$$"
    log "Baixando $rdir/$fname..."
    if printf 'get %s/%s %s\n' "$rdir" "$fname" "$tmp_path" | sftp_batch >/dev/null 2>>"$LOG"; then
      mv -f "$tmp_path" "$local_path"
      new_downloads=$((new_downloads + 1))
    else
      rm -f "$tmp_path"
      fail "falha ao baixar $rdir/$fname."
    fi
  done
done

(( remote_tar_total > 0 )) || fail "a VPS não apresentou nenhum snapshot .tar.gz em $REMOTE_ROOT/daily ou $REMOTE_ROOT/weekly."
log "Novos arquivos baixados: $new_downloads"

# Valida todo tar ainda sem marcador .ok.
shopt -s nullglob
for f in "$LOCAL_MOUNT"/daily/*.tar.gz "$LOCAL_MOUNT"/weekly/*.tar.gz; do
  [[ -f "$f.ok" ]] && continue
  sum_file="$f.sha256"
  if [[ ! -f "$sum_file" ]]; then
    log "AVISO: $(basename "$f") ainda não tem .sha256; esta execução não será considerada concluída enquanto o par não chegar."
    continue
  fi
  if (cd "$(dirname "$f")" && sha256sum -c "$(basename "$sum_file")" >/dev/null 2>&1) && tar -tzf "$f" >/dev/null 2>&1; then
    touch "$f.ok"
    validated=$((validated + 1))
    log "Integridade OK: $(basename "$f")"
  else
    rejected=$((rejected + 1))
    epoch="$(date +%s)"
    suspect="$f.suspeito-$epoch"
    log "FALHA DE INTEGRIDADE: $(basename "$f"). Preservando cópias suspeitas e recusando a execução."
    mv -f "$f" "$suspect"
    [[ -f "$sum_file" ]] && mv -f "$sum_file" "$sum_file.suspeito-$epoch"
  fi
done
shopt -u nullglob

# O remoto pode ter sido listado, mas o .sha256 ainda não ter chegado. Não aceita falso sucesso.
missing_valid=0
for entry in "${remote_archives[@]}"; do
  kind="${entry%%|*}"
  fname="${entry#*|}"
  if [[ ! -f "$LOCAL_MOUNT/$kind/$fname.ok" ]]; then
    log "PENDENTE: $kind/$fname ainda não possui validação .ok local."
    missing_valid=$((missing_valid + 1))
  fi
done

(( rejected == 0 )) || fail "$rejected snapshot(s) rejeitado(s) por integridade."
(( missing_valid == 0 )) || fail "$missing_valid snapshot(s) remoto(s) ainda não estão íntegros/validados localmente."

# A VPS, por padrão, mantém apenas um snapshot diário. Para preservar uma
# retenção semanal sem ocupar espaço extra na VPS, qualquer snapshot diário
# de domingo validado é promovido localmente para weekly no HD externo.
promote_sunday_dailies(){
  local f fname stamp ymd iso_date weekly hash
  shopt -s nullglob
  for f in "$LOCAL_MOUNT"/daily/portal-*.tar.gz; do
    [[ -f "$f.ok" ]] || continue
    fname="$(basename "$f")"
    if [[ "$fname" =~ ^portal-([0-9]{8})-([0-9]{6})\.tar\.gz$ ]]; then
      ymd="${BASH_REMATCH[1]}"
      stamp="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
      iso_date="${ymd:0:4}-${ymd:4:2}-${ymd:6:2}"
      [[ "$(date -d "$iso_date" +%u 2>/dev/null || echo 0)" == "7" ]] || continue
      weekly="$LOCAL_MOUNT/weekly/portal-weekly-$stamp.tar.gz"
      [[ -f "$weekly.ok" ]] && continue
      if [[ -e "$weekly" || -e "$weekly.sha256" ]]; then
        log "AVISO: semanal parcial encontrado para $stamp; removendo antes de recriar."
        rm -f -- "$weekly" "$weekly.sha256" "$weekly.ok"
      fi
      if ! ln "$f" "$weekly" 2>/dev/null; then
        cp -a "$f" "$weekly"
      fi
      hash="$(sha256sum "$weekly" | awk '{print $1}')"
      printf '%s  %s\n' "$hash" "$(basename "$weekly")" > "$weekly.sha256"
      touch "$weekly.ok"
      log "Promovido para semanal no HD: $(basename "$weekly")"
    fi
  done
  shopt -u nullglob
}
promote_sunday_dailies

# Retenção: remove apenas snapshots já validados. Um arquivo novo incompleto nunca expulsa o último backup bom.
rotate_validated(){
  local dir="$1" keep="$2"
  local oks=() archive i
  mapfile -t oks < <(find "$dir" -maxdepth 1 -type f -name '*.tar.gz.ok' -printf '%f\n' 2>/dev/null | sort -r)
  if (( ${#oks[@]} > keep )); then
    for ((i = keep; i < ${#oks[@]}; i++)); do
      archive="${oks[$i]%.ok}"
      rm -f -- "$dir/$archive" "$dir/$archive.sha256" "$dir/$archive.ok"
      log "Retenção local removeu snapshot validado: $archive"
    done
  fi
}
rotate_validated "$LOCAL_MOUNT/daily" "$KEEP_DAILY_LOCAL"
rotate_validated "$LOCAL_MOUNT/weekly" "$KEEP_WEEKLY_LOCAL"

write_status ok
log "Coleta concluída com sucesso. remote=$remote_tar_total new=$new_downloads validated=$validated rejected=$rejected"
trap - EXIT
exit 0
