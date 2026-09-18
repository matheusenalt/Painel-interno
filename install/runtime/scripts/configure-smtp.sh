#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_ENCRYPTION="${SMTP_ENCRYPTION:-tls}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM_NAME="${SMTP_FROM_NAME:-Portal Interno}"

[[ -n "$SMTP_HOST" ]] || read -rp "Servidor SMTP (ex.: smtp.exemplo.invalid): " SMTP_HOST
[[ -n "$SMTP_USER" ]] || read -rp "E-mail/usuário SMTP: " SMTP_USER
[[ "$SMTP_USER" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "E-mail SMTP inválido." >&2; exit 1; }
[[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || { echo "Porta SMTP inválida." >&2; exit 1; }
[[ "$SMTP_ENCRYPTION" == "ssl" || "$SMTP_ENCRYPTION" == "tls" ]] || { echo "SMTP_ENCRYPTION deve ser ssl ou tls." >&2; exit 1; }

SMTP_DOMAIN="${SMTP_USER#*@}"
SMTP_FROM="${SMTP_USER%@*}"

if [[ -z "$SMTP_PASSWORD" ]]; then
  read -rsp "Senha do e-mail $SMTP_USER: " SMTP_PASSWORD
  echo
fi
[[ -n "$SMTP_PASSWORD" ]] || { echo "Senha vazia; cancelado." >&2; exit 1; }

occ(){ docker exec -u www-data portal-nextcloud php occ "$@"; }

echo "[SMTP] Configurando Nextcloud..."
occ config:system:set mail_smtpmode --value="smtp" >/dev/null
occ config:system:set mail_smtphost --value="$SMTP_HOST" >/dev/null
occ config:system:set mail_smtpport --type=integer --value="$SMTP_PORT" >/dev/null
occ config:system:set mail_smtpsecure --value="$SMTP_ENCRYPTION" >/dev/null
occ config:system:set mail_smtpauth --type=boolean --value=true >/dev/null
occ config:system:set mail_smtpauthtype --value="LOGIN" >/dev/null
occ config:system:set mail_smtpname --value="$SMTP_USER" >/dev/null
occ config:system:set mail_smtppassword --value="$SMTP_PASSWORD" >/dev/null
occ config:system:set mail_from_address --value="$SMTP_FROM" >/dev/null
occ config:system:set mail_domain --value="$SMTP_DOMAIN" >/dev/null
occ user:setting "${NEXTCLOUD_ADMIN_USER:-admin}" settings email "$SMTP_USER" >/dev/null 2>&1 || true

echo "[SMTP] Configurando FoxDesk..."
PASS_B64="$(printf '%s' "$SMTP_PASSWORD" | base64 -w0)"
HOST_B64="$(printf '%s' "$SMTP_HOST" | base64 -w0)"
USER_B64="$(printf '%s' "$SMTP_USER" | base64 -w0)"
NAME_B64="$(printf '%s' "$SMTP_FROM_NAME" | base64 -w0)"
ENC_B64="$(printf '%s' "$SMTP_ENCRYPTION" | base64 -w0)"
cat <<SQL | docker exec -i portal-foxdesk-db mariadb -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME"
INSERT INTO settings (setting_key, setting_value) VALUES
('smtp_host',FROM_BASE64('$HOST_B64')),
('smtp_port','$SMTP_PORT'),
('smtp_user',FROM_BASE64('$USER_B64')),
('smtp_pass',FROM_BASE64('$PASS_B64')),
('smtp_from_email',FROM_BASE64('$USER_B64')),
('smtp_from_name',FROM_BASE64('$NAME_B64')),
('smtp_encryption',FROM_BASE64('$ENC_B64')),
('email_notifications_enabled','1')
ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value);
SQL

unset SMTP_PASSWORD PASS_B64 HOST_B64 USER_B64 NAME_B64 ENC_B64
cat <<'TXT'
[SMTP] Configuração gravada.
Faça um teste de envio pelo painel administrativo do Nextcloud e do FoxDesk.
Se o provedor rejeitar a combinação atual de porta/criptografia, consulte a documentação oficial do serviço SMTP utilizado.
TXT
