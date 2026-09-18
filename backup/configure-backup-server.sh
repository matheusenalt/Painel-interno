#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ $EUID -eq 0 ]] || { echo "ERRO: execute com sudo." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

BACKUP_MODE="${BACKUP_MODE:-pull}"
BACKUP_SFTP_USER="${BACKUP_SFTP_USER:-backupreader}"
BACKUP_EXPORT_ROOT="${BACKUP_EXPORT_ROOT:-/srv/portal-backup-sftp}"
AUTHORIZED_KEYS_DIR="/etc/ssh/authorized_keys"
SSHD_DROPIN="/etc/ssh/sshd_config.d/90-portal-backup.conf"

[[ "$BACKUP_MODE" == "pull" ]] || { echo "Backup mode '$BACKUP_MODE': SFTP pull não será configurado."; exit 0; }

if ! getent group "$BACKUP_SFTP_USER" >/dev/null 2>&1; then
  groupadd --system "$BACKUP_SFTP_USER"
fi
if ! id "$BACKUP_SFTP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$BACKUP_SFTP_USER" --no-create-home --home-dir / --shell /usr/sbin/nologin "$BACKUP_SFTP_USER"
fi
# Algumas combinações de sshd/PAM rejeitam contas com hash de senha travado antes mesmo da chave pública.
# Removemos o hash, mas PasswordAuthentication=no + AuthenticationMethods=publickey + ForceCommand SFTP
# mantêm a conta sem login por senha e sem shell.
passwd -d "$BACKUP_SFTP_USER" >/dev/null 2>&1 || true

install -d -o root -g root -m 0755 "$BACKUP_EXPORT_ROOT"
install -d -o root -g "$BACKUP_SFTP_USER" -m 0750 "$BACKUP_EXPORT_ROOT/files"
install -d -o root -g "$BACKUP_SFTP_USER" -m 0750 "$BACKUP_EXPORT_ROOT/files/daily" "$BACKUP_EXPORT_ROOT/files/weekly"
find "$BACKUP_EXPORT_ROOT/files" -maxdepth 2 -type f \( -name '*.tar.gz' -o -name '*.sha256' \) -exec chown root:"$BACKUP_SFTP_USER" {} + 2>/dev/null || true
find "$BACKUP_EXPORT_ROOT/files" -maxdepth 2 -type f -name '*.tar.gz' -exec chmod 0640 {} + 2>/dev/null || true
find "$BACKUP_EXPORT_ROOT/files" -maxdepth 2 -type f -name '*.sha256' -exec chmod 0640 {} + 2>/dev/null || true
install -d -o root -g root -m 0755 "$AUTHORIZED_KEYS_DIR"
touch "$AUTHORIZED_KEYS_DIR/$BACKUP_SFTP_USER"
chown root:root "$AUTHORIZED_KEYS_DIR/$BACKUP_SFTP_USER"
chmod 0644 "$AUTHORIZED_KEYS_DIR/$BACKUP_SFTP_USER"

cat > "$SSHD_DROPIN" <<CFG
# Portal Interno - conta de backup somente leitura via SFTP.
# A chave privada fica exclusivamente na VM de backup.
Match User $BACKUP_SFTP_USER
    ChrootDirectory $BACKUP_EXPORT_ROOT
    ForceCommand internal-sftp -R
    PasswordAuthentication no
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    AuthorizedKeysFile $AUTHORIZED_KEYS_DIR/%u
    PermitTTY no
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
CFG
chmod 0644 "$SSHD_DROPIN"

if ! /usr/sbin/sshd -t; then
  rm -f "$SSHD_DROPIN"
  echo "ERRO: configuração SSH de backup inválida; alteração revertida." >&2
  exit 1
fi
systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true

echo "[OK] Usuário $BACKUP_SFTP_USER criado/revisado."
echo "[OK] SFTP read-only: $BACKUP_EXPORT_ROOT -> /files para a VM de backup."
echo "[OK] Autenticação por senha desabilitada para essa conta."
echo "Para autorizar a VM de backup, rode depois:"
echo "  sudo $ROOT/scripts/configurar-chave-backup.sh /caminho/CHAVE_PUBLICA_DA_VM.pub"
