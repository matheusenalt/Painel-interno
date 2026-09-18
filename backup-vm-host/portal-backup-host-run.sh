#!/usr/bin/env bash
# Orquestrador do NOTEBOOK:
# energia -> internet -> desmonta com segurança o HD do host -> liga VM ->
# VirtualBox captura USB -> espera coleta/desligamento -> HD volta -> lê status.
set -Eeuo pipefail

MODE="${1:-manual}"
[[ "$MODE" =~ ^(manual|nightly|daytime)$ ]] || { echo "Modo inválido: $MODE" >&2; exit 2; }
CONF="/etc/portal-backup-host/host.env"
STATE_DIR="/var/lib/portal-backup-host"
STATE_FILE="$STATE_DIR/last-run.json"
LOG="/var/log/portal-backup-host.log"
STATUS_MOUNT="/mnt/portal-backup-status"

log(){ printf '[%s] [%s] %s\n' "$(date -Is)" "$MODE" "$*" | tee -a "$LOG"; }
[[ -f "$CONF" ]] || { log "ERRO: $CONF não encontrado. Rode install-host.sh."; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

VBOX_USER="${VBOX_USER:?}"
VM_NAME="${VM_NAME:?}"
HD_UUID="${HD_UUID:?}"
MIN_BATTERY_PERCENT="${MIN_BATTERY_PERCENT:-30}"
DAYTIME_STALE_HOURS="${DAYTIME_STALE_HOURS:-20}"
VM_BOOT_TIMEOUT_SEC="${VM_BOOT_TIMEOUT_SEC:-14400}"
HD_RETURN_TIMEOUT_SEC="${HD_RETURN_TIMEOUT_SEC:-90}"
SUSPEND_AFTER_NIGHTLY="${SUSPEND_AFTER_NIGHTLY:-true}"

install -d -m 0755 "$STATE_DIR"
vbox(){ runuser -u "$VBOX_USER" -- VBoxManage "$@"; }

write_state(){
  local status="$1" prev_success="null" success_field
  if [[ -f "$STATE_FILE" ]]; then
    prev_success="$(sed -n 's/.*"last_success"[[:space:]]*:[[:space:]]*\("[^"]*"\|null\).*/\1/p' "$STATE_FILE" | head -n1)"
    [[ -n "$prev_success" ]] || prev_success="null"
  fi
  success_field="$prev_success"
  [[ "$status" == "ok" ]] && success_field="\"$(date -Is)\""
  printf '{"mode":"%s","last_attempt":"%s","status":"%s","last_success":%s}\n' \
    "$MODE" "$(date -Is)" "$status" "$success_field" > "$STATE_FILE"
}

hours_since_last_success(){
  [[ -f "$STATE_FILE" ]] || { echo 999999; return; }
  local last_success last_epoch now_epoch
  last_success="$(sed -n 's/.*"last_success"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n1)"
  [[ -n "$last_success" ]] || { echo 999999; return; }
  last_epoch="$(date -d "$last_success" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  echo $(( (now_epoch - last_epoch) / 3600 ))
}

if [[ "$MODE" == "daytime" ]]; then
  stale_h="$(hours_since_last_success)"
  if (( stale_h < DAYTIME_STALE_HOURS )); then
    log "Backup recente (${stale_h}h < ${DAYTIME_STALE_HOURS}h). Nada a fazer."
    exit 0
  fi
  log "Backup atrasado (${stale_h}h). Tentando agora."
fi

# Energia: sem BAT* = desktop/host sem bateria, portanto não bloqueia.
shopt -s nullglob
battery_paths=(/sys/class/power_supply/BAT*/capacity)
ac_paths=(/sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online /sys/class/power_supply/DP*/online)
shopt -u nullglob
on_ac=0
for online in "${ac_paths[@]}"; do [[ "$(cat "$online" 2>/dev/null || echo 0)" == "1" ]] && on_ac=1; done
batt_ok=0
for cap in "${battery_paths[@]}"; do c="$(cat "$cap" 2>/dev/null || echo 0)"; (( c >= MIN_BATTERY_PERCENT )) && batt_ok=1; done
if (( ${#battery_paths[@]} > 0 && on_ac == 0 && batt_ok == 0 )); then
  log "PULANDO: sem tomada e bateria abaixo de ${MIN_BATTERY_PERCENT}%."
  write_state skipped_power
  exit 0
fi

VPS_HOST="${VPS_HOST:-}"
VPS_PORT="${VPS_PORT:-22}"
if [[ -z "$VPS_HOST" ]] || ! nc -z -w5 "$VPS_HOST" "$VPS_PORT" >/dev/null 2>&1; then
  log "PULANDO: endpoint SFTP da VPS indisponível agora (${VPS_HOST:-não definido}:$VPS_PORT)."
  write_state skipped_internet
  exit 0
fi

hd_device="$(blkid -U "$HD_UUID" 2>/dev/null || true)"
if [[ -z "$hd_device" ]]; then
  log "PULANDO: HD com UUID=$HD_UUID não está conectado ao host."
  write_state skipped_hd
  exit 0
fi
parent_name="$(lsblk -no PKNAME "$hd_device" 2>/dev/null | head -n1 || true)"
parent_dev="${parent_name:+/dev/$parent_name}"
[[ -n "$parent_dev" ]] || parent_dev="$hd_device"
log "HD localizado em $hd_device (dispositivo USB pai: $parent_dev)."

# O VirtualBox vai capturar o dispositivo USB inteiro. Antes disso, desmonta
# todas as partições montadas desse mesmo disco para evitar remoção a quente
# de filesystem ainda ativo no host (ambientes gráficos podem montar a mídia automaticamente).
safe_unmount_usb_disk(){
  local dev target
  mapfile -t devs < <(lsblk -lnpo NAME "$parent_dev" 2>/dev/null | tac)
  for dev in "${devs[@]}"; do
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      log "Desmontando com segurança $dev de '$target' antes do passthrough..."
      sync
      umount "$target" || return 1
    done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
  done
}
if ! safe_unmount_usb_disk; then
  log "PULANDO: não consegui desmontar o HD com segurança no host. Feche arquivos/janelas que estejam usando o HD externo."
  write_state skipped_hd_busy
  exit 0
fi

vm_state="$(vbox showvminfo "$VM_NAME" --machinereadable | sed -n 's/^VMState="\(.*\)"$/\1/p')"
case "$vm_state" in
  poweroff|aborted)
    run_started_epoch="$(date +%s)"
    rm -f "$STATE_DIR/last-vm-run.json"
    log "Ligando VM '$VM_NAME' (headless). O filtro USB deve capturar o HD automaticamente..."
    vbox startvm "$VM_NAME" --type headless >/dev/null
    ;;
  *)
    log "ERRO: VM '$VM_NAME' deveria estar desligada, mas está em '$vm_state'. Não vou interferir."
    write_state failed
    exit 1
    ;;
esac

elapsed=0; step=15; vm_off=0
while (( elapsed < VM_BOOT_TIMEOUT_SEC )); do
  if ! vbox list runningvms | grep -qF "\"$VM_NAME\""; then vm_off=1; break; fi
  sleep "$step"
  elapsed=$((elapsed + step))
done

if (( vm_off == 0 )); then
  log "ERRO: VM não desligou em ${VM_BOOT_TIMEOUT_SEC}s. Forçando poweroff; investigar antes de confiar no backup."
  vbox controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
fi

# Depois do poweroff, o VirtualBox devolve o USB ao host. Aguarda a partição
# reaparecer e lê o status escrito pela VM. O host monta somente leitura se
# o sistema do host ainda não tiver montado por conta própria.
hd_device=""
for ((elapsed=0; elapsed<HD_RETURN_TIMEOUT_SEC; elapsed+=2)); do
  hd_device="$(blkid -U "$HD_UUID" 2>/dev/null || true)"
  [[ -n "$hd_device" ]] && break
  sleep 2
done

run_status="failed"
if [[ -z "$hd_device" ]]; then
  log "AVISO: HD não reapareceu no host em ${HD_RETURN_TIMEOUT_SEC}s após o desligamento da VM."
else
  status_root="$(findmnt -rn -S "$hd_device" -o TARGET 2>/dev/null | head -n1 || true)"
  mounted_by_us=0
  if [[ -z "$status_root" ]]; then
    install -d -m 0755 "$STATUS_MOUNT"
    if mount -o ro "$hd_device" "$STATUS_MOUNT" 2>>"$LOG"; then
      status_root="$STATUS_MOUNT"
      mounted_by_us=1
    else
      # O automount do host pode ter ocorrido entre o findmnt e o mount.
      status_root="$(findmnt -rn -S "$hd_device" -o TARGET 2>/dev/null | head -n1 || true)"
    fi
  fi

  if [[ -n "$status_root" && -f "$status_root/logs/last-run.json" ]]; then
    cp -f "$status_root/logs/last-run.json" "$STATE_DIR/last-vm-run.json"
    vm_attempt="$(sed -n 's/.*"last_attempt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_DIR/last-vm-run.json" | head -n1)"
    vm_attempt_epoch="$(date -d "$vm_attempt" +%s 2>/dev/null || echo 0)"
    if grep -q '"status":"ok"' "$STATE_DIR/last-vm-run.json" 2>/dev/null \
       && (( vm_attempt_epoch >= ${run_started_epoch:-0} )); then
      run_status="ok"
    else
      log "AVISO: status da VM não é sucesso desta execução (last_attempt=$vm_attempt)."
    fi
    log "Status da VM: $(cat "$STATE_DIR/last-vm-run.json")"
  else
    log "AVISO: a VM não deixou logs/last-run.json acessível no HD nesta execução."
  fi

  if (( mounted_by_us )); then
    umount "$STATUS_MOUNT" 2>/dev/null || log "AVISO: não consegui desmontar $STATUS_MOUNT."
  fi
fi

(( vm_off == 0 )) && run_status="failed"
write_state "$run_status"
[[ "$run_status" == "ok" ]] && log "Coleta concluída com sucesso." || log "Coleta falhou nesta tentativa."

if [[ "$MODE" == "nightly" && "$SUSPEND_AFTER_NIGHTLY" == "true" ]]; then
  if ! loginctl list-sessions --no-legend 2>/dev/null | grep -q . && ! who | grep -q .; then
    log "Nenhuma sessão detectada. Suspendendo em 30s."
    sleep 30
    systemctl suspend
  else
    log "Sessão de usuário detectada — não vou suspender o notebook."
  fi
fi

[[ "$run_status" == "ok" ]] || exit 1
exit 0
