#!/usr/bin/env bash
set -uo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/portal.json}"
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "ERRO: $CONFIG_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

failures=0
warnings=0
ok(){ printf '  [OK] %s\n' "$*"; }
warn(){ printf '  [AVISO] %s\n' "$*"; warnings=$((warnings+1)); }
fail(){ printf '  [FALHA] %s\n' "$*" >&2; failures=$((failures+1)); }
occ(){ docker exec -u www-data portal-nextcloud php occ "$@"; }

printf '\n=== Portal Interno | Auditoria de segurança ===\n'
printf 'Perfil: %s\n\n' "${DEPLOY_PROFILE:-desconhecido}"

if [[ "${DEPLOY_PROFILE:-homologacao}" == "prod" ]]; then
  [[ "${BIND_ADDRESS:-}" == "127.0.0.1" ]] && ok "backends web presos ao loopback" || fail "BIND_ADDRESS deveria ser 127.0.0.1 em produção"
else
  warn "perfil de homologação: HTTP/LAN não representa a camada final de produção"
fi

for port in 3306 6379; do
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
    fail "porta sensível $port está escutando no host"
  else
    ok "porta sensível $port não publicada no host"
  fi
done

if ufw status 2>/dev/null | grep -q '^Status: active'; then ok "UFW ativo"; else fail "UFW não está ativo"; fi
if systemctl is-active --quiet fail2ban 2>/dev/null; then ok "Fail2ban ativo"; else warn "Fail2ban não está ativo"; fi
if dpkg -s unattended-upgrades >/dev/null 2>&1; then ok "unattended-upgrades instalado"; else warn "unattended-upgrades ausente"; fi

if occ config:system:get auth.bruteforce.protection.enabled 2>/dev/null | grep -qi '^false$'; then
  fail "proteção nativa contra brute force foi desativada"
else
  ok "proteção nativa contra brute force não está desativada"
fi

apps="$(occ app:list --enabled --output=json 2>/dev/null || echo '{}')"
for app in password_policy twofactor_totp; do
  if jq -e --arg a "$app" '.enabled | has($a)' <<<"$apps" >/dev/null 2>&1; then ok "app de segurança habilitado: $app"; else fail "app de segurança ausente: $app"; fi
done

minlen="$(occ config:app:get password_policy minLength 2>/dev/null || true)"
[[ "$minlen" =~ ^[0-9]+$ && "$minlen" -ge 12 ]] && ok "política de senha: mínimo $minlen caracteres" || warn "política de senha mínima não confirmada como >=12"

if [[ -f /root/portal-credenciais-iniciais.txt ]]; then
  mode="$(stat -c '%a' /root/portal-credenciais-iniciais.txt 2>/dev/null || echo '?')"
  [[ "$mode" == "600" ]] && warn "credenciais iniciais ainda existem em /root (modo 600); remova após onboarding" || fail "arquivo de credenciais iniciais existe com permissão inesperada: $mode"
else
  ok "arquivo de credenciais iniciais já foi removido"
fi

if [[ -f /etc/cron.d/portal-nextcloud ]]; then ok "cron do Nextcloud instalado"; else fail "cron do Nextcloud ausente"; fi
if [[ -f /etc/cron.d/portal-backup ]]; then ok "cron de backup instalado"; else fail "cron de backup ausente"; fi
if systemctl is-active --quiet portal-control.service 2>/dev/null; then ok "controle de backup/restauração ativo"; else fail "portal-control.service inativo"; fi
if [[ -S /run/portal-control/control.sock ]]; then
  smode="$(stat -c '%a' /run/portal-control/control.sock 2>/dev/null || echo '?')"
  sgroup="$(stat -c '%G' /run/portal-control/control.sock 2>/dev/null || echo '?')"
  [[ "$smode" == "660" && "$sgroup" == "portalctl" ]] && ok "socket de controle restrito (660 portalctl)" || fail "permissão inesperada no socket: $smode $sgroup"
else fail "socket do controle ausente"; fi
if jq -e '.enabled | has("portalbackup")' <<<"$apps" >/dev/null 2>&1; then ok "app administrativo portalbackup habilitado"; else fail "app portalbackup ausente"; fi

if [[ "${DEPLOY_PROFILE:-homologacao}" == "prod" ]]; then
  if [[ "${BACKUP_MODE:-pull}" == "pull" ]]; then
    backup_user="${BACKUP_SFTP_USER:-backupreader}"
    backup_root="${BACKUP_EXPORT_ROOT:-/srv/portal-backup-sftp}"
    keyfile="/etc/ssh/authorized_keys/$backup_user"
    id "$backup_user" >/dev/null 2>&1 && ok "conta de backup SFTP existe" || fail "conta de backup SFTP ausente"
    [[ -s "$keyfile" ]] && ok "VM de backup pareada por chave pública" || fail "VM de backup ainda não possui chave autorizada"
    grep -q 'ForceCommand internal-sftp -R' /etc/ssh/sshd_config.d/90-portal-backup.conf 2>/dev/null && ok "SFTP do backup é somente leitura" || fail "SFTP do backup não está confirmado como read-only"
    latest="$(find "$backup_root/files/daily" -maxdepth 1 -type f -name 'portal-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    if [[ -n "$latest" && -f "$latest.sha256" ]]; then
      if (cd "$(dirname "$latest")" && sha256sum -c "$(basename "$latest").sha256" >/dev/null 2>&1); then ok "último snapshot exportado possui SHA-256 válido"; else fail "checksum do último snapshot exportado falhou"; fi
      if find "$latest" -mmin -1800 -print -quit | grep -q .; then ok "último snapshot exportado tem menos de 30h"; else warn "último snapshot exportado tem mais de 30h"; fi
    else
      fail "nenhum snapshot exportado com checksum foi encontrado"
    fi
  else
    if mountpoint -q /mnt/backup-portal; then ok "destino externo de backup montado"; else fail "/mnt/backup-portal não é um mount separado"; fi
  fi

  if [[ -n "${NEXTCLOUD_DOMAIN:-}" ]]; then
    if curl -fsSIk --max-time 12 "https://${NEXTCLOUD_DOMAIN}" >/tmp/portal-hdr.$$ 2>/dev/null; then
      ok "Nextcloud responde por HTTPS"
      if grep -qi '^strict-transport-security:' /tmp/portal-hdr.$$; then ok "HSTS presente no Nextcloud"; else warn "HSTS não foi encontrado no Nextcloud"; fi
    else
      fail "Nextcloud não respondeu por HTTPS em ${NEXTCLOUD_DOMAIN}"
    fi
    rm -f /tmp/portal-hdr.$$
  else
    fail "domínio Nextcloud não declarado"
  fi

  if [[ -n "${FOXDESK_DOMAIN:-}" ]] && curl -fsSIk --max-time 12 "https://${FOXDESK_DOMAIN}" >/dev/null 2>&1; then
    ok "FoxDesk responde por HTTPS"
  else
    fail "FoxDesk não respondeu por HTTPS ou domínio não declarado"
  fi

  trusted_proxy_count="$(occ config:system:get trusted_proxies 2>/dev/null | grep -c . || true)"
  if [[ "$trusted_proxy_count" -gt 0 ]]; then ok "trusted_proxies configurado"; else warn "trusted_proxies ainda não está configurado; necessário se houver reverse proxy separado"; fi
else
  warn "HTTPS/HSTS/trusted_proxies serão auditados no perfil prod"
fi

smtp_mode="$(occ config:system:get mail_smtpmode 2>/dev/null || true)"
smtp_host="$(occ config:system:get mail_smtphost 2>/dev/null || true)"
if [[ "$smtp_mode" == "smtp" && -n "$smtp_host" && "$smtp_host" != "127.0.0.1" ]]; then ok "SMTP configurado ($smtp_host)"; else warn "SMTP ainda precisa ser validado"; fi

if docker exec portal-foxdesk test ! -e /var/www/html/install.php; then ok "install.php do FoxDesk removido"; else fail "install.php do FoxDesk ainda existe"; fi

printf '\nResultado: %d falha(s), %d aviso(s).\n' "$failures" "$warnings"
if (( failures > 0 )); then
  exit 1
fi
