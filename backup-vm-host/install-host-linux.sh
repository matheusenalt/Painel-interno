#!/usr/bin/env bash
# Portal Interno - instalador no NOTEBOOK host da VM de backup.
# Arquitetura atual: o HD externo é capturado diretamente pela VM via USB passthrough.
set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/portal-backup-host"
CONF_FILE="$CONF_DIR/host.env"
STATE_DIR="/var/lib/portal-backup-host"

log(){ printf '\n\033[1;34m[Portal Backup Host]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
valid_uint(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }

[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo ./install-host-linux.sh"
command -v VBoxManage >/dev/null 2>&1 || die "VBoxManage não encontrado. Instale o VirtualBox primeiro."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends netcat-openbsd util-linux >/dev/null

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || warn "Pensado para Debian. Detectado: ${PRETTY_NAME:-desconhecido}."
fi

cat <<'BANNER'
============================================================
 Portal Interno - Notebook host da VM de backup
 Arquitetura: USB passthrough direto do HD para a VM
============================================================
BANNER

if [[ -f "$CONF_FILE" ]]; then
  warn "Já existe $CONF_FILE. Vou reaproveitar os valores atuais onde fizer sentido."
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

DEFAULT_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
read -r -p "Usuário do notebook que possui a VM no VirtualBox (Enter para '$DEFAULT_USER'): " input_user
VBOX_USER="${VBOX_USER:-${input_user:-$DEFAULT_USER}}"
id "$VBOX_USER" >/dev/null 2>&1 || die "Usuário '$VBOX_USER' não existe."

mapfile -t vm_list < <(runuser -u "$VBOX_USER" -- VBoxManage list vms | sed -E 's/^"([^"]+)".*/\1/')
if (( ${#vm_list[@]} > 0 )); then
  printf 'VMs encontradas para %s:\n' "$VBOX_USER"
  printf '  - %s\n' "${vm_list[@]}"
fi
read -r -p "Nome exato da VM de backup (Enter para '${VM_NAME:-PORTAL-BACKUP}'): " input_vm
VM_NAME="${VM_NAME:-${input_vm:-PORTAL-BACKUP}}"
runuser -u "$VBOX_USER" -- VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1 || die "VM '$VM_NAME' não existe para $VBOX_USER."

log "Discos/partições disponíveis no host:"
lsblk -f -o NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS | sed 's/^/  /'
read -r -p "UUID da partição do HD externo de backup: " input_uuid
HD_UUID="${HD_UUID:-$input_uuid}"
[[ -n "$HD_UUID" ]] || die "UUID é obrigatório."
HD_DEVICE="$(blkid -U "$HD_UUID" 2>/dev/null || true)"
[[ -n "$HD_DEVICE" ]] || die "UUID '$HD_UUID' não está presente agora. Conecte o HD e confira com lsblk -f."

parent_name="$(lsblk -no PKNAME "$HD_DEVICE" 2>/dev/null | head -n1 || true)"
if [[ -n "$parent_name" ]]; then
  parent_dev="/dev/$parent_name"
  transport="$(lsblk -ndo TRAN "$parent_dev" 2>/dev/null | head -n1 || true)"
  [[ "$transport" == "usb" ]] || warn "O dispositivo pai $parent_dev não informou transporte USB (TRAN='${transport:-?}'). Confirme que este é realmente o HD externo correto."
fi

log "Verificando filtros USB da VM..."
usb_section="$(runuser -u "$VBOX_USER" -- VBoxManage showvminfo "$VM_NAME" 2>/dev/null | sed -n '/USB Device Filters:/,/Bandwidth groups:/p' || true)"
if [[ -n "$usb_section" ]]; then
  printf '%s\n' "$usb_section" | sed 's/^/  /'
else
  warn "Não consegui listar filtros USB. O instalador NÃO cria nem altera filtros automaticamente."
fi
cat <<'TXT'

O HD deve ser capturado automaticamente pela VM quando ela ligar.
Teste esperado: ao iniciar PORTAL-BACKUP, o HD some do host; ao desligar a VM, ele volta.
Se isso ainda não acontece, configure um filtro USB do HD no VirtualBox antes de ativar a automação.
TXT
read -r -p "A captura automática do HD pela VM já foi testada e funciona? [s/N]: " usb_ok
[[ "$usb_ok" =~ ^[sS]$ ]] || die "Configure/teste o filtro USB da VM e rode este instalador novamente."

read -r -p "Percentual mínimo de bateria sem tomada (Enter para 30): " input_batt
MIN_BATTERY_PERCENT="${MIN_BATTERY_PERCENT:-${input_batt:-30}}"
valid_uint "$MIN_BATTERY_PERCENT" && (( MIN_BATTERY_PERCENT <= 100 )) || die "Percentual inválido."
read -r -p "Host/IP da VPS para checar o SFTP: " input_vps_host
VPS_HOST="${VPS_HOST:-$input_vps_host}"
[[ -n "$VPS_HOST" ]] || die "Host/IP da VPS é obrigatório."
read -r -p "Porta SFTP/SSH da VPS (Enter para 22): " input_vps_port
VPS_PORT="${VPS_PORT:-${input_vps_port:-22}}"
valid_uint "$VPS_PORT" && (( VPS_PORT <= 65535 )) || die "Porta inválida."

read -r -p "Horas sem sucesso para tentar durante o dia (Enter para 20): " input_stale
DAYTIME_STALE_HOURS="${DAYTIME_STALE_HOURS:-${input_stale:-20}}"
valid_uint "$DAYTIME_STALE_HOURS" || die "Horas devem ser inteiro > 0."

install -d -m 0755 "$CONF_DIR" "$STATE_DIR"
cat > "$CONF_FILE" <<ENV
VBOX_USER=$VBOX_USER
VM_NAME=$VM_NAME
HD_UUID=$HD_UUID
MIN_BATTERY_PERCENT=$MIN_BATTERY_PERCENT
VPS_HOST=$VPS_HOST
VPS_PORT=$VPS_PORT
DAYTIME_STALE_HOURS=$DAYTIME_STALE_HOURS
# Até 4h para transferências grandes sem matar a VM no meio.
VM_BOOT_TIMEOUT_SEC=14400
# Tempo para o HD reaparecer no host depois que a VM devolver o USB.
HD_RETURN_TIMEOUT_SEC=90
# Se a tentativa noturna acordou o notebook e ninguém está logado, volta a suspender.
SUSPEND_AFTER_NIGHTLY=true
ENV
chmod 0644 "$CONF_FILE"

install -m 0750 -o root -g root "$SOURCE_DIR/portal-backup-host-run.sh" /usr/local/sbin/portal-backup-host-run.sh
for unit in portal-backup-host-nightly.service portal-backup-host-nightly.timer portal-backup-host-daytime.service portal-backup-host-daytime.timer; do
  install -m 0644 "$SOURCE_DIR/timers/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now portal-backup-host-nightly.timer portal-backup-host-daytime.timer

cat <<EOF2

============================================================
 NOTEBOOK CONFIGURADO COMO HOST DA VM DE BACKUP
============================================================
 VM:               $VM_NAME (VirtualBox: $VBOX_USER)
 HD monitorado:    UUID=$HD_UUID
 Transporte:       USB passthrough direto para a VM
 Shared folder:    NÃO utilizado

 Teste manual:
   sudo /usr/local/sbin/portal-backup-host-run.sh manual

 Status:
   cat $STATE_DIR/last-run.json
   cat $STATE_DIR/last-vm-run.json 2>/dev/null || true
   sudo journalctl -u portal-backup-host-nightly.service -e

 Timers:
   systemctl list-timers 'portal-backup-host-*'
============================================================
EOF2
