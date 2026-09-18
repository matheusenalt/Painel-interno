#!/usr/bin/env bash
# Reconstrói uma VPS limpa usando um snapshot do Portal Interno como fonte de estado/dados.
# O repositório fornece o runtime; o snapshot fornece bancos, volumes, .env e portal.json.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RUNTIME="$HERE/runtime"
TARGET="/opt/portal-interno"
BACKUP=""
CHECKSUM=""
NC_DOMAIN=""
FOX_DOMAIN=""

usage(){ cat <<'USAGE'
Uso:
  sudo ./install/install-from-backup.sh --backup /caminho/portal-AAAA....tar.gz \
       [--checksum /caminho/portal-AAAA....tar.gz.sha256] \
       [--nextcloud-domain SEU_DOMINIO] [--foxdesk-domain SEU_SUBDOMINIO]

O snapshot precisa conter portal-config.tar.gz. Backups antigos sem host-config.tar.gz
continuam restauráveis, mas o módulo Gestão de Equipe poderá exigir configuração
segura entregue separadamente.
USAGE
}
while (( $# )); do
  case "$1" in
    --backup) BACKUP="${2:-}"; shift 2;;
    --checksum) CHECKSUM="${2:-}"; shift 2;;
    --nextcloud-domain) NC_DOMAIN="${2:-}"; shift 2;;
    --foxdesk-domain) FOX_DOMAIN="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Opção desconhecida: $1" >&2; usage; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "ERRO: execute com sudo/root." >&2; exit 1; }
[[ -n "$BACKUP" && -f "$BACKUP" ]] || { echo "ERRO: informe --backup com um arquivo existente." >&2; usage; exit 1; }
BACKUP="$(readlink -f "$BACKUP")"
[[ -z "$CHECKSUM" || -f "$CHECKSUM" ]] || { echo "ERRO: checksum não encontrado: $CHECKSUM" >&2; exit 1; }
[[ ! -e "$TARGET/.env" ]] || { echo "ERRO: $TARGET já contém um ambiente. Use uma VPS limpa." >&2; exit 1; }

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == ubuntu && ( "${VERSION_ID:-}" == 22.04 || "${VERSION_ID:-}" == 24.04 ) ]] || {
    echo "ERRO: fluxo automatizado validado para Ubuntu Server 22.04/24.04; detectado ${PRETTY_NAME:-desconhecido}." >&2; exit 1; }
else echo "ERRO: /etc/os-release ausente." >&2; exit 1; fi

valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
while ! valid_domain "$NC_DOMAIN"; do read -r -p "Domínio público do Nextcloud: " NC_DOMAIN; done
while ! valid_domain "$FOX_DOMAIN"; do read -r -p "Domínio público do FoxDesk: " FOX_DOMAIN; done

cat <<EOF
Reconstrução por backup:
  Snapshot:  $BACKUP
  Nextcloud: https://$NC_DOMAIN
  FoxDesk:   https://$FOX_DOMAIN

O snapshot pode conter segredos operacionais antigos (.env). Eles serão usados apenas
localmente na nova VPS e nunca serão copiados para este repositório.
EOF
read -r -p "Digite RESTAURAR para continuar: " confirm
[[ "$confirm" == RESTAURAR ]] || { echo "Cancelado."; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq openssl python3 rsync ufw fail2ban unattended-upgrades cron openssh-server tar gzip

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker cron

if [[ -n "$CHECKSUM" ]]; then
  expected="$(awk 'NF{print $1; exit}' "$CHECKSUM")"
  actual="$(sha256sum "$BACKUP" | awk '{print $1}')"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "${expected,,}" == "${actual,,}" ]] || { echo "ERRO: SHA-256 externo não confere." >&2; exit 1; }
  echo "[DR] SHA-256 externo: OK"
elif [[ -f "$BACKUP.sha256" ]]; then
  expected="$(awk 'NF{print $1; exit}' "$BACKUP.sha256")"; actual="$(sha256sum "$BACKUP" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || { echo "ERRO: SHA-256 externo não confere." >&2; exit 1; }
  echo "[DR] SHA-256 externo: OK"
else
  echo "[AVISO] .sha256 não fornecido. O manifest interno ainda será validado."
fi

WORK="$(mktemp -d /var/tmp/portal-dr.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
python3 "$REPO_ROOT/backup/validate-backup.py" "$BACKUP" "$WORK"
[[ -f "$WORK/portal-config.tar.gz" ]] || { echo "ERRO: snapshot sem portal-config.tar.gz; não é possível reconstruir a configuração automaticamente." >&2; exit 1; }
mkdir -p "$WORK/config"
tar -xzf "$WORK/portal-config.tar.gz" -C "$WORK/config" --no-same-owner --no-same-permissions
[[ -f "$WORK/config/.env" ]] || { echo "ERRO: portal-config.tar.gz não contém .env." >&2; exit 1; }

# Runtime conhecido do repositório prevalece; estado declarativo e segredos vêm do snapshot.
mkdir -p "$TARGET"
rsync -a --delete --exclude 'config/portal.json' --exclude '.env' "$RUNTIME/" "$TARGET/"
install -m 0600 "$WORK/config/.env" "$TARGET/.env"
if [[ -f "$WORK/config/config/portal.json" ]]; then
  install -d -m 0755 "$TARGET/config"
  install -m 0600 "$WORK/config/config/portal.json" "$TARGET/config/portal.json"
else
  echo "ERRO: snapshot não contém config/portal.json dentro de portal-config.tar.gz." >&2; exit 1
fi

# Host protected config is optional in legacy snapshots.
install -d -m 0700 /etc/portal-interno
printf 'prod\n' > /etc/portal-interno/environment; chmod 600 /etc/portal-interno/environment
if [[ -f "$WORK/host-config.tar.gz" ]]; then
  mkdir -p "$WORK/hostcfg"
  tar -xzf "$WORK/host-config.tar.gz" -C "$WORK/hostcfg" --no-same-owner --no-same-permissions
  if [[ -f "$WORK/hostcfg/etc/portal-interno/team.json" ]]; then
    install -m 0600 "$WORK/hostcfg/etc/portal-interno/team.json" /etc/portal-interno/team.json
  fi
fi

# Resolve novo IP local e grupo do socket; senhas de banco/Redis permanecem as do snapshot
# porque o config.php restaurado precisa falar com esses mesmos segredos.
HOST_IP="$(ip -4 route get 192.0.2.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -n "$HOST_IP" ]] || HOST_IP="$(hostname -I | awk '{print $1}')"
getent group portalctl >/dev/null || groupadd --system portalctl
PORTAL_CONTROL_GID="$(getent group portalctl | cut -d: -f3)"

python3 - "$TARGET/.env" "$HOST_IP" "$PORTAL_CONTROL_GID" "$NC_DOMAIN" "$FOX_DOMAIN" <<'PYENV'
from pathlib import Path
import sys
p=Path(sys.argv[1]); vals={}
for line in p.read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k,v=line.split('=',1); vals[k]=v
vals.update({
 'DEPLOY_PROFILE':'prod','HOST_IP':sys.argv[2],'BIND_ADDRESS':'127.0.0.1',
 'PORTAL_CONTROL_GID':sys.argv[3],'CONFIG_FILE':'/opt/portal-interno/config/portal.json',
 'NEXTCLOUD_DOMAIN':sys.argv[4],'FOXDESK_DOMAIN':sys.argv[5],
 'NEXTCLOUD_PUBLIC_URL':'https://'+sys.argv[4], 'FOXDESK_PUBLIC_URL':'https://'+sys.argv[5]
})
# Recria preservando chaves existentes e adicionando as necessárias.
order=[]
for line in p.read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k=line.split('=',1)[0]
        if k not in order: order.append(k)
for k in vals:
    if k not in order: order.append(k)
p.write_text('\n'.join(f'{k}={vals[k]}' for k in order)+'\n')
PYENV
chmod 600 "$TARGET/.env"

# Atualiza portal.json apenas nos domínios; identidade/usuários permanecem os do snapshot.
tmp_cfg="$(mktemp)"
jq --arg nc "$NC_DOMAIN" --arg fx "$FOX_DOMAIN" '.network.production.scheme="https" | .network.production.nextcloud_domain=$nc | .network.production.foxdesk_domain=$fx' "$TARGET/config/portal.json" > "$tmp_cfg"
install -m 0600 "$tmp_cfg" "$TARGET/config/portal.json"; rm -f "$tmp_cfg"

# Compose exige o arquivo de secret mesmo com Nextcloud já instalado. Este valor novo NÃO troca
# a senha do admin restaurado; serve apenas para satisfazer o secret do compose/entrypoint.
install -d -m 0700 "$TARGET/secrets"
openssl rand -hex 32 > "$TARGET/secrets/nextcloud_admin_password"
chmod 600 "$TARGET/secrets/nextcloud_admin_password"

set -a; source "$TARGET/.env"; set +a
cd "$TARGET"
PORTAL_ROOT="$TARGET" "$TARGET/scripts/install-backup-control.sh"
docker compose pull nextcloud-db redis foxdesk-db
docker compose build --pull nextcloud foxdesk
docker pull alpine:3.22 >/dev/null

# Rotinas recorrentes da VPS.
install -m 0644 "$TARGET/cron/portal-nextcloud" /etc/cron.d/portal-nextcloud
install -m 0644 "$TARGET/cron/portal-foxdesk" /etc/cron.d/portal-foxdesk
install -m 0644 "$TARGET/cron/portal-backup" /etc/cron.d/portal-backup
systemctl restart cron

# Prepara SFTP de backup; a chave da VM NÃO está no Git e deve ser autorizada depois.
if [[ "${BACKUP_MODE:-pull}" == pull ]]; then PORTAL_ROOT="$TARGET" "$TARGET/scripts/configure-backup-server.sh"; fi

# Restaura dados; healthcheck completo é adiado porque HTTPS ainda será configurado.
PORTAL_ROOT="$TARGET" "$TARGET/scripts/restore.sh" --yes --skip-final-healthcheck "$BACKUP"

# Reinstala Gestão de Equipe somente se o backup trouxe a configuração protegida.
if [[ -f /etc/portal-interno/team.json && -x "$TARGET/team-management/install-team-management.sh" ]]; then
  TEAM_CONFIG_SRC=/etc/portal-interno/team.json "$TARGET/team-management/install-team-management.sh"
elif docker exec -u www-data portal-nextcloud php occ app:list --enabled 2>/dev/null | grep -q 'teammanager'; then
  echo "[AVISO] Backup legado sem /etc/portal-interno/team.json. Desabilitando temporariamente teammanager até a configuração segura ser entregue."
  docker exec -u www-data portal-nextcloud php occ app:disable teammanager >/dev/null 2>&1 || true
fi

# Hardening básico sem assumir porta SSH.
mapfile -t SSH_PORTS < <(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un)
(( ${#SSH_PORTS[@]} )) || SSH_PORTS=(22)
for p in "${SSH_PORTS[@]}"; do ufw allow "$p/tcp" >/dev/null; done
ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw --force enable >/dev/null || true
cat > /etc/fail2ban/jail.d/portal-ssh.conf <<'JAIL'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
systemctl enable --now fail2ban >/dev/null 2>&1 || true

echo
read -r -p "O DNS dos dois domínios já aponta para esta nova VPS e você quer configurar HTTPS agora? [s/N]: " https_now
if [[ "$https_now" =~ ^[sS]$ ]]; then
  PORTAL_ROOT="$TARGET" "$TARGET/scripts/configurar-https.sh"
  echo "[DR] Executando validação final..."
  PORTAL_ROOT="$TARGET" "$TARGET/scripts/healthcheck.sh"
  PORTAL_ROOT="$TARGET" "$TARGET/scripts/auditar-seguranca.sh" || echo "[AVISO] A auditoria encontrou ponto(s) para revisão."
  echo "[DR] Reconstrução concluída. Valide os dois sites no navegador e reautorize a chave pública da VM de backup."
else
  cat <<EOF

[DR] Dados restaurados. Próximos passos OBRIGATÓRIOS:
1. Aponte o DNS de $NC_DOMAIN e $FOX_DOMAIN para esta nova VPS.
2. Aguarde a propagação.
3. Rode: sudo $TARGET/scripts/configurar-https.sh
4. Rode: sudo $TARGET/scripts/healthcheck.sh
5. Rode: sudo $TARGET/scripts/auditar-seguranca.sh
6. Reautorize a chave PÚBLICA da VM de backup com configurar-chave-backup.sh.

Não libere o ambiente antes de o healthcheck terminar sem falhas reais.
EOF
fi
trap - EXIT; rm -rf "$WORK"
