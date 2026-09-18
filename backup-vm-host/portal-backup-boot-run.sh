#!/usr/bin/env bash
# Roda uma vez a cada boot da VM. O host liga a VM, o VirtualBox entrega o
# HD externo inteiro por USB passthrough, a VM monta a partição pelo UUID,
# puxa/valida os snapshots e desliga.
set -Eeuo pipefail

CONF="/etc/portal-backup/backup.env"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"
LOCAL_MOUNT="${LOCAL_MOUNT:-/mnt/portal-backups}"
LOG="/var/log/portal-backup-boot.log"
log(){ printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "Boot da VM de backup. Aguardando rede e HD externo em $LOCAL_MOUNT..."

ready=0
for _ in $(seq 1 45); do
  # Acessar o caminho dispara x-systemd.automount. Não basta mountpoint -q,
  # porque um autofs vazio também aparece como mountpoint.
  ls -A "$LOCAL_MOUNT" >/dev/null 2>&1 || true
  fstype="$(findmnt -T "$LOCAL_MOUNT" -n -o FSTYPE 2>/dev/null || true)"
  if systemctl is-active --quiet network-online.target 2>/dev/null \
     && [[ -n "$fstype" && "$fstype" != "autofs" ]] \
     && runuser -u backupreader -- test -w "$LOCAL_MOUNT"; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" != "1" ]]; then
  log "ERRO: HD externo não montou com escrita para backupreader (ou rede não subiu). Nada foi escrito no disco errado."
else
  log "Pronto. Rodando portal-backup-pull.service..."
  if systemctl start --wait portal-backup-pull.service; then
    log "Coleta concluída com sucesso."
  else
    log "Coleta terminou com erro — ver /var/log/portal-backup-pull.log e 'journalctl -u portal-backup-pull.service'."
  fi
fi

sync
log "Desligando a VM (fim do trabalho)."
systemctl poweroff
