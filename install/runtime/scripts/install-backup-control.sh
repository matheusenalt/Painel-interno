#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ $EUID -eq 0 ]] || { echo "ERRO: execute como root." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
GROUP=portalctl
getent group "$GROUP" >/dev/null || groupadd --system "$GROUP"
GID_NOW="$(getent group "$GROUP" | cut -d: -f3)"
[[ "${PORTAL_CONTROL_GID:-}" == "$GID_NOW" ]] || { echo "ERRO: PORTAL_CONTROL_GID=${PORTAL_CONTROL_GID:-vazio} mas grupo $GROUP usa GID $GID_NOW. Corrija .env antes de subir o Nextcloud." >&2; exit 1; }
RESTORE_INBOX="${RESTORE_INBOX:-/srv/portal-restore-inbox}"
RESTORE_TMP="${RESTORE_TMP:-/srv/portal-restore-tmp}"
install -d -o root -g "$GROUP" -m 0770 "$RESTORE_INBOX"
# PHP/Apache no container roda como uid 33 e recebe o grupo suplementar portalctl.
install -d -o 33 -g "$GROUP" -m 0770 "$RESTORE_TMP"
install -m 0644 "$ROOT/control/portal-control.service" /etc/systemd/system/portal-control.service
systemctl daemon-reload
systemctl enable --now portal-control.service
for _ in $(seq 1 20); do [[ -S /run/portal-control/control.sock ]] && break; sleep .25; done
[[ -S /run/portal-control/control.sock ]] || { systemctl status portal-control.service --no-pager >&2 || true; exit 1; }
echo "[controle] Serviço portal-control ativo; socket restrito pronto."
