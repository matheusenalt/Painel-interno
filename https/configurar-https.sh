#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
CONFIG_FILE="$ROOT/config/portal.json"
CADDYFILE="/etc/caddy/Caddyfile"

log(){ printf '\n\033[1;34m[HTTPS]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo ./configurar-https.sh"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE não encontrado. Rode install-portal.sh antes."

# shellcheck disable=SC1090
source "$ENV_FILE"

[[ "${DEPLOY_PROFILE:-}" == "prod" ]] || die "Este script é só para o perfil prod. Ambiente atual: ${DEPLOY_PROFILE:-desconhecido}."
[[ -n "${NEXTCLOUD_DOMAIN:-}" && -n "${FOXDESK_DOMAIN:-}" ]] || die "NEXTCLOUD_DOMAIN/FOXDESK_DOMAIN vazios em $ENV_FILE. Rode install-portal.sh de novo ou preencha manualmente."

log "Domínios configurados: $NEXTCLOUD_DOMAIN (Nextcloud) e $FOXDESK_DOMAIN (FoxDesk)"

# --- Checagem de DNS ------------------------------------------------------
PUBLIC_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$PUBLIC_IP" ]]; then
  warn "Não consegui detectar o IP público da VPS automaticamente. Vou seguir sem checar o DNS."
else
  log "IP público detectado desta VPS: $PUBLIC_IP"
  for d in "$NEXTCLOUD_DOMAIN" "$FOXDESK_DOMAIN"; do
    resolved="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    if [[ -z "$resolved" ]]; then
      warn "$d ainda não resolve para nenhum IP. O DNS pode não ter sido criado ou ainda não propagou."
    elif [[ "$resolved" != "$PUBLIC_IP" ]]; then
      warn "$d resolve para $resolved, mas o IP desta VPS é $PUBLIC_IP. Confira o registro DNS tipo A."
    else
      log "$d já aponta corretamente para esta VPS."
    fi
  done
  read -r -p "Continuar mesmo assim? [S/n]: " continue_dns
  [[ ! "$continue_dns" =~ ^[nN]$ ]] || die "Ajuste o DNS e rode este script de novo."
fi

# Caddy pode emitir/renovar certificados ACME sem e-mail de contato.
# Nenhum e-mail é solicitado nesta implantação.

# --- Instalação do Caddy ---------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
  log "Instalando Caddy (emite e renova o certificado TLS sozinho)..."
  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update
  apt-get install -y caddy
else
  log "Caddy já está instalado."
fi

# --- Caddyfile --------------------------------------------------------------
log "Gerando $CADDYFILE..."
cat > "$CADDYFILE" <<CADDY
$NEXTCLOUD_DOMAIN {
    redir /.well-known/carddav /remote.php/dav 301
    redir /.well-known/caldav /remote.php/dav 301
    encode gzip
    reverse_proxy 127.0.0.1:${NEXTCLOUD_PORT:-8080}
    header Strict-Transport-Security "max-age=15552000; includeSubDomains"
}

$FOXDESK_DOMAIN {
    encode gzip
    reverse_proxy 127.0.0.1:${FOXDESK_PORT:-8081}
}
CADDY

log "Validando Caddyfile..."
caddy validate --config "$CADDYFILE" || die "Caddyfile inválido. Revise $CADDYFILE."

# --- Firewall ----------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

# --- Sobe/recarrega o Caddy ----------------------------------------------
systemctl enable --now caddy >/dev/null 2>&1 || true
systemctl reload caddy 2>/dev/null || systemctl restart caddy

log "Aguardando o Caddy emitir os certificados (pode levar até ~1 minuto na primeira vez)..."
sleep 10

CERT_OK=1
for d in "$NEXTCLOUD_DOMAIN" "$FOXDESK_DOMAIN"; do
  if curl -fsS -o /dev/null "https://$d/"; then
    log "https://$d respondendo com certificado válido."
  else
    warn "https://$d ainda não respondeu OK. Rode 'sudo journalctl -u caddy -n 80 --no-pager' para ver o motivo (geralmente é DNS ainda propagando)."
    CERT_OK=0
  fi
done

# --- Reforça as URLs internas do Nextcloud/FoxDesk -------------------------
if docker ps --format '{{.Names}}' | grep -q '^portal-nextcloud$'; then
  docker exec -u www-data portal-nextcloud php occ config:system:set trusted_domains 2 --value="$NEXTCLOUD_DOMAIN" >/dev/null 2>&1 || true
  docker exec -u www-data portal-nextcloud php occ config:system:set overwrite.cli.url --value="https://$NEXTCLOUD_DOMAIN" >/dev/null 2>&1 || true
  docker exec -u www-data portal-nextcloud php occ config:system:set overwriteprotocol --value="https" >/dev/null 2>&1 || true
  docker exec -u www-data portal-nextcloud php occ config:system:set overwritehost --value="$NEXTCLOUD_DOMAIN" >/dev/null 2>&1 || true
fi

# Em migração/DR o volume restaurado do FoxDesk pode conter APP_URL da VPS/domínio anterior.
# Atualiza somente APP_URL, preservando SECRET_KEY e credenciais restauradas.
if docker ps --format '{{.Names}}' | grep -q '^portal-foxdesk$'; then
  docker exec -e PORTAL_NEW_FOX_URL="https://$FOXDESK_DOMAIN" portal-foxdesk php -r '
$p="/var/www/html/config.php";
$s=@file_get_contents($p); if($s===false){fwrite(STDERR,"config.php ausente\n"); exit(1);}
$url=getenv("PORTAL_NEW_FOX_URL");
$replacement="define(\x27APP_URL\x27, ".var_export($url,true).");";
$n=0; $out=preg_replace("/define\(\x27APP_URL\x27,\s*[^;]+\);/",$replacement,$s,1,$n);
if($n!==1 || $out===null){fwrite(STDERR,"APP_URL não localizado\n"); exit(2);}
if(file_put_contents($p,$out)===false){exit(3);}
' || warn "Não consegui atualizar APP_URL do FoxDesk automaticamente; revise /var/www/html/config.php dentro do container."
fi

cat <<EOF

============================================================
 HTTPS configurado via Caddy
============================================================
 Nextcloud: https://$NEXTCLOUD_DOMAIN
 FoxDesk:   https://$FOXDESK_DOMAIN

 Certificado: emitido automaticamente pelo Caddy (Let's Encrypt) e renovado sozinho.
 Config:      $CADDYFILE
 Logs:        sudo journalctl -u caddy -f

 Ainda manual:
   - HSTS já habilitado no Nextcloud; confirme em Administração > Visão geral.
   - Ativar 2FA obrigatório só depois de todos cadastrarem o segundo fator.
   - Rodar: sudo $ROOT/scripts/healthcheck.sh
============================================================
EOF

[[ "$CERT_OK" == "1" ]] || warn "Pelo menos um domínio não respondeu em HTTPS ainda. Normalmente é DNS propagando — tente de novo em alguns minutos."
