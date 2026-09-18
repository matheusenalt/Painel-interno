#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ $EUID -eq 0 ]] || { echo "ERRO: execute com sudo." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
USER_NAME="${BACKUP_SFTP_USER:-backupreader}"
DEST="/etc/ssh/authorized_keys/$USER_NAME"
SRC="${1:-}"

usage(){ echo "Uso: sudo $0 /caminho/chave-publica.pub  (ou '-' para ler do stdin)" >&2; exit 2; }
[[ -n "$SRC" ]] || usage
if [[ "$SRC" == "-" ]]; then
  IFS= read -r key
else
  [[ -f "$SRC" ]] || { echo "ERRO: arquivo não encontrado: $SRC" >&2; exit 1; }
  key="$(head -n1 "$SRC" | tr -d '\r')"
fi

[[ "$key" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh.com)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || {
  echo "ERRO: use uma chave pública Ed25519 válida da VM de backup." >&2
  exit 1
}

install -d -o root -g root -m 0755 /etc/ssh/authorized_keys
printf '%s\n' "$key" > "$DEST"
chown root:root "$DEST"
chmod 0644 "$DEST"
/usr/sbin/sshd -t
systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true

echo "[OK] Chave da VM de backup autorizada para $USER_NAME."
echo "A conta continua limitada a SFTP somente leitura, sem shell e sem senha."
