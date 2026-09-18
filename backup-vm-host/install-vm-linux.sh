#!/usr/bin/env bash
# Portal Interno - instalador da VM de backup.
# Arquitetura atual: HD externo entregue diretamente à VM por USB passthrough.
# Uso normal: sudo ./install-vm-linux.sh
# Trocar apenas VPS mantendo chave e armazenamento: sudo ./install-vm-linux.sh --reconfigure
set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/portal-backup"
CONF_FILE="$CONF_DIR/backup.env"
BACKUP_USER="backupreader"
BACKUP_HOME="/home/$BACKUP_USER"
LOCAL_MOUNT="/mnt/portal-backups"
RECONFIGURE=0
[[ "${1:-}" == "--reconfigure" ]] && RECONFIGURE=1
[[ $# -le 1 ]] || { echo "Uso: sudo $0 [--reconfigure]" >&2; exit 2; }

log(){ printf '\n\033[1;34m[Portal Backup VM]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
valid_uint(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }

[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo ./install-vm-linux.sh"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || warn "Este instalador foi pensado para Debian. Detectado: ${PRETTY_NAME:-desconhecido}. Seguindo mesmo assim."
fi

cat <<'BANNER'
============================================================
 Portal Interno - VM de Backup
 VPS -> SFTP pull -> HD externo via USB passthrough
============================================================
BANNER

log "Instalando dependências..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends openssh-client ca-certificates util-linux exfatprogs kmod >/dev/null

log "Criando usuário de serviço '$BACKUP_USER' (sem shell, sem sudo)..."
if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$BACKUP_HOME" --shell /usr/sbin/nologin "$BACKUP_USER"
fi
install -d -o "$BACKUP_USER" -g "$BACKUP_USER" -m 0700 "$BACKUP_HOME/.ssh"

if [[ ! -f "$BACKUP_HOME/.ssh/id_ed25519" ]]; then
  log "Gerando par de chaves Ed25519 dedicado (fica só nesta VM)..."
  runuser -u "$BACKUP_USER" -- ssh-keygen -t ed25519 -N '' -C "backupreader@$(hostname)" -f "$BACKUP_HOME/.ssh/id_ed25519"
else
  log "Chave existente mantida em $BACKUP_HOME/.ssh/id_ed25519."
fi
: > /dev/null
[[ -f "$BACKUP_HOME/.ssh/known_hosts" ]] || touch "$BACKUP_HOME/.ssh/known_hosts"
chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME/.ssh/known_hosts"
chmod 600 "$BACKUP_HOME/.ssh/known_hosts"

cp -f "$BACKUP_HOME/.ssh/id_ed25519.pub" /root/backupreader-public-key.pub
chmod 600 /root/backupreader-public-key.pub

# Reaproveita configuração antiga quando existe.
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

configure_connection(){
  local input_host input_port fp scan_out fp_ok input_daily input_weekly
  read -r -p "IP ou domínio da VPS (Portal Interno) [${VPS_HOST:-}]: " input_host
  VPS_HOST="${input_host:-${VPS_HOST:-}}"
  [[ -n "$VPS_HOST" ]] || die "IP/domínio da VPS é obrigatório."
  read -r -p "Porta SSH da VPS (Enter para '${VPS_PORT:-22}'): " input_port
  VPS_PORT="${input_port:-${VPS_PORT:-22}}"
  valid_uint "$VPS_PORT" && (( VPS_PORT <= 65535 )) || die "Porta SSH inválida: $VPS_PORT"

  log "Buscando a chave pública SSH da VPS..."
  if scan_out="$(ssh-keyscan -p "$VPS_PORT" -t ed25519 "$VPS_HOST" 2>/dev/null)" && [[ -n "$scan_out" ]]; then
    fp="$(printf '%s\n' "$scan_out" | ssh-keygen -lf - 2>/dev/null | head -n1)"
    printf '\nFingerprint recebido de %s:%s:\n  %s\n' "$VPS_HOST" "$VPS_PORT" "$fp"
    warn "Confirme na própria VPS: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    read -r -p "O fingerprint bate com o mostrado na VPS? [s/N]: " fp_ok
    [[ "$fp_ok" =~ ^[sS]$ ]] || die "Pareamento cancelado."
    : > "$BACKUP_HOME/.ssh/known_hosts"
    printf '%s\n' "$scan_out" >> "$BACKUP_HOME/.ssh/known_hosts"
    chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME/.ssh/known_hosts"
    chmod 600 "$BACKUP_HOME/.ssh/known_hosts"
  else
    die "Não consegui contatar $VPS_HOST:$VPS_PORT. Confira rede/firewall e tente de novo."
  fi

  read -r -p "Retenção local: diários no HD externo (Enter para ${KEEP_DAILY_LOCAL:-7}): " input_daily
  KEEP_DAILY_LOCAL="${input_daily:-${KEEP_DAILY_LOCAL:-7}}"
  valid_uint "$KEEP_DAILY_LOCAL" || die "Retenção diária deve ser inteiro > 0."
  read -r -p "Retenção local: semanais no HD externo (Enter para ${KEEP_WEEKLY_LOCAL:-4}): " input_weekly
  KEEP_WEEKLY_LOCAL="${input_weekly:-${KEEP_WEEKLY_LOCAL:-4}}"
  valid_uint "$KEEP_WEEKLY_LOCAL" || die "Retenção semanal deve ser inteiro > 0."
}

configure_storage(){
  local input_uuid hd_device fstype backup_uid backup_gid opts tmp existing_target
  log "Discos/partições visíveis dentro da VM:"
  lsblk -f -o NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS | sed 's/^/  /'
  read -r -p "UUID da partição do HD externo usada para backup [${BACKUP_DISK_UUID:-}]: " input_uuid
  BACKUP_DISK_UUID="${input_uuid:-${BACKUP_DISK_UUID:-}}"
  [[ -n "$BACKUP_DISK_UUID" ]] || die "UUID do HD de backup é obrigatório."
  hd_device="$(blkid -U "$BACKUP_DISK_UUID" 2>/dev/null || true)"
  [[ -n "$hd_device" ]] || die "UUID '$BACKUP_DISK_UUID' não está visível na VM. Confirme o USB passthrough/filtro do VirtualBox."
  fstype="$(blkid -s TYPE -o value "$hd_device" 2>/dev/null || true)"
  [[ -n "$fstype" ]] || die "Não consegui identificar o filesystem de $hd_device."
  BACKUP_DISK_FSTYPE="$fstype"

  backup_uid="$(id -u "$BACKUP_USER")"
  backup_gid="$(id -g "$BACKUP_USER")"
  case "$fstype" in
    exfat|vfat|fat|ntfs|ntfs3)
      opts="uid=$backup_uid,gid=$backup_gid,fmask=0077,dmask=0077,nofail,x-systemd.automount,x-systemd.device-timeout=10"
      ;;
    *)
      opts="nofail,x-systemd.automount,x-systemd.device-timeout=10"
      ;;
  esac
  FSTAB_LINE="UUID=$BACKUP_DISK_UUID $LOCAL_MOUNT $fstype $opts 0 0"

  mkdir -p "$LOCAL_MOUNT"
  existing_target="$(findmnt -rn -S "$hd_device" -o TARGET 2>/dev/null | head -n1 || true)"
  if [[ -n "$existing_target" && "$existing_target" != "$LOCAL_MOUNT" ]]; then
    warn "O HD está montado em '$existing_target' dentro da VM; desmontando para aplicar a configuração definitiva."
    umount "$existing_target" || die "Não consegui desmontar $existing_target."
  fi

  cp -a /etc/fstab "/etc/fstab.backupreader.bak.$(date +%Y%m%d-%H%M%S)"
  tmp="$(mktemp)"
  awk -v mp="$LOCAL_MOUNT" '($2 != mp) && !($1 == "portal-backups" && $3 == "vboxsf") {print}' /etc/fstab > "$tmp"
  printf '%s\n' "$FSTAB_LINE" >> "$tmp"
  cat "$tmp" > /etc/fstab
  rm -f "$tmp"
  systemctl daemon-reload

  # Monta de verdade agora para validar. Em revisões antigas o autofs vazio
  # enganava mountpoint -q; aqui exigimos filesystem real + escrita do usuário.
  umount "$LOCAL_MOUNT" 2>/dev/null || true
  mount "$LOCAL_MOUNT" || die "Não consegui montar $BACKUP_DISK_UUID em $LOCAL_MOUNT."
  if [[ ! "$fstype" =~ ^(exfat|vfat|fat|ntfs|ntfs3)$ ]]; then
    chown "$BACKUP_USER:$BACKUP_USER" "$LOCAL_MOUNT"
    chmod 0700 "$LOCAL_MOUNT"
  fi
  runuser -u "$BACKUP_USER" -- touch "$LOCAL_MOUNT/.backupreader-write-test" \
    || die "$LOCAL_MOUNT montou, mas $BACKUP_USER não consegue escrever. Revise filesystem/permissões."
  rm -f "$LOCAL_MOUNT/.backupreader-write-test"
  log "HD validado: $hd_device ($fstype) -> $LOCAL_MOUNT com escrita para $BACKUP_USER."
}

# --reconfigure troca apenas o destino SFTP/retenção e mantém a chave/HD.
if [[ "$RECONFIGURE" == "1" ]]; then
  [[ -f "$CONF_FILE" ]] || die "--reconfigure exige instalação anterior ($CONF_FILE)."
  log "Reconfigurando VPS/retenção sem trocar a chave privada nem o HD..."
  configure_connection
  [[ -n "${BACKUP_DISK_UUID:-}" ]] || configure_storage
else
  configure_connection
  configure_storage
fi

install -d -m 0755 "$CONF_DIR"
cat > "$CONF_FILE" <<ENV
VPS_HOST=$VPS_HOST
VPS_PORT=$VPS_PORT
VPS_USER=backupreader
REMOTE_ROOT=/files
LOCAL_MOUNT=$LOCAL_MOUNT
BACKUP_DISK_UUID=$BACKUP_DISK_UUID
BACKUP_DISK_FSTYPE=${BACKUP_DISK_FSTYPE:-}
KEEP_DAILY_LOCAL=$KEEP_DAILY_LOCAL
KEEP_WEEKLY_LOCAL=$KEEP_WEEKLY_LOCAL
ENV
chown root:"$BACKUP_USER" "$CONF_FILE"
chmod 0640 "$CONF_FILE"

# Logs e executáveis.
touch /var/log/portal-backup-pull.log /var/log/portal-backup-boot.log
chown "$BACKUP_USER:$BACKUP_USER" /var/log/portal-backup-pull.log
chmod 0640 /var/log/portal-backup-pull.log
chown root:root /var/log/portal-backup-boot.log
chmod 0640 /var/log/portal-backup-boot.log

install -m 0750 -o root -g "$BACKUP_USER" "$SOURCE_DIR/portal-backup-pull.sh" /usr/local/sbin/portal-backup-pull.sh
install -m 0750 -o root -g root "$SOURCE_DIR/portal-backup-boot-run.sh" /usr/local/sbin/portal-backup-boot-run.sh
install -m 0750 -o root -g root "$SOURCE_DIR/testar-portal-backup" /usr/local/sbin/testar-portal-backup
install -m 0644 "$SOURCE_DIR/../backup/systemd/portal-backup-pull.service" /etc/systemd/system/portal-backup-pull.service
install -m 0644 "$SOURCE_DIR/../backup/systemd/portal-backup-boot.service" /etc/systemd/system/portal-backup-boot.service
systemctl daemon-reload
systemctl enable portal-backup-boot.service >/dev/null

cat <<EOF2

============================================================
 VM DE BACKUP CONFIGURADA
============================================================
 HD direto na VM: UUID=$BACKUP_DISK_UUID -> $LOCAL_MOUNT
 Chave pública para autorizar na VPS:
   /root/backupreader-public-key.pub

 Na VPS:
   sudo /opt/portal-interno/scripts/configurar-chave-backup.sh /caminho/CHAVE_PUBLICA_DA_VM.pub

 Observação da implantação real:
   /etc/ssh/authorized_keys/backupreader deve ficar root:root 0644 na VPS.

 Depois, nesta VM:
   sudo testar-portal-backup

 Coleta manual completa:
   sudo systemctl start --wait portal-backup-pull.service
   sudo journalctl -u portal-backup-pull.service -e
============================================================
EOF2
