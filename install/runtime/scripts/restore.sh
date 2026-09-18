#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERRO: $ENV_FILE não encontrado." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
if [[ "${PORTAL_LOCK_HELD:-0}" != "1" ]]; then exec 9>/run/portal-interno-maintenance.lock; flock -n 9 || { echo "ERRO: outra operação de backup/restauração está em andamento." >&2; exit 75; }; fi

assume_yes=0
skip_final_healthcheck=0
while [[ "${1:-}" == --* ]]; do
  case "${1:-}" in
    --yes) assume_yes=1; shift ;;
    --skip-final-healthcheck) skip_final_healthcheck=1; shift ;;
    *) echo "Opção desconhecida: ${1:-}" >&2; exit 2 ;;
  esac
done
archive="${1:-}"
[[ -n "$archive" && -f "$archive" ]] || { echo "Uso: sudo $0 [--yes] [--skip-final-healthcheck] /caminho/portal-AAAAMMDD-HHMMSS.tar.gz" >&2; exit 1; }
archive="$(readlink -f "$archive")"
if [[ "$assume_yes" != "1" ]]; then
  echo "ATENÇÃO: esta restauração SOBRESCREVE os dados atuais de Nextcloud e FoxDesk."
  read -r -p "Digite RESTAURAR para continuar: " confirm
  [[ "$confirm" == "RESTAURAR" ]] || { echo "Cancelado."; exit 1; }
fi

if [[ -f "$archive.sha256" ]]; then
  echo "[restore] Validando SHA-256 externo..."
  (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256") >/dev/null || { echo "ERRO: SHA-256 externo não confere." >&2; exit 1; }
fi
WORK_ROOT="${RESTORE_TMP:-/srv/portal-restore-tmp}"
mkdir -p "$WORK_ROOT"
work="$(mktemp -d "$WORK_ROOT/restore-work.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "[restore] Validando e extraindo backup de forma segura..."
"$ROOT/scripts/validate-backup.py" "$archive" "$work"

cd "$ROOT"
echo "[restore] Parando o portal..."
docker compose down

echo "[restore] Restaurando volumes de aplicação..."
for volume in portal-nextcloud-app portal-foxdesk-app; do
  docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null
  docker run --rm -v "$volume:/volume" alpine:3.22 sh -c 'find /volume -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
done
docker run --rm -v portal-nextcloud-app:/volume -v "$work:/backup:ro" alpine:3.22 tar -xf /backup/nextcloud-volume.tar -C /volume
docker run --rm -v portal-foxdesk-app:/volume -v "$work:/backup:ro" alpine:3.22 tar -xf /backup/foxdesk-volume.tar -C /volume

echo "[restore] Subindo bancos e Redis..."
docker compose up -d nextcloud-db redis foxdesk-db
wait_healthy(){
  local c="$1"
  for _ in $(seq 1 90); do [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || true)" == "healthy" ]] && return 0; sleep 2; done
  echo "ERRO: $c não ficou saudável." >&2; docker logs --tail 100 "$c" >&2 || true; return 1
}
wait_healthy portal-nextcloud-db; wait_healthy portal-redis; wait_healthy portal-foxdesk-db

echo "[restore] Recriando bancos e importando dumps..."
docker exec portal-nextcloud-db mariadb -uroot -p"$NC_DB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$NC_DB_NAME\`; CREATE DATABASE \`$NC_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; GRANT ALL PRIVILEGES ON \`$NC_DB_NAME\`.* TO '$NC_DB_USER'@'%'; FLUSH PRIVILEGES;"
docker exec -i portal-nextcloud-db mariadb -u"$NC_DB_USER" -p"$NC_DB_PASSWORD" "$NC_DB_NAME" < "$work/nextcloud.sql"
docker exec portal-foxdesk-db mariadb -uroot -p"$FOX_DB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$FOX_DB_NAME\`; CREATE DATABASE \`$FOX_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$FOX_DB_NAME\`.* TO '$FOX_DB_USER'@'%'; FLUSH PRIVILEGES;"
docker exec -i portal-foxdesk-db mariadb -u"$FOX_DB_USER" -p"$FOX_DB_PASSWORD" "$FOX_DB_NAME" < "$work/foxdesk.sql"

echo "[restore] Limpando cache/locks do Redis para evitar estado antigo após rollback..."
docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" portal-redis redis-cli FLUSHALL >/dev/null

echo "[restore] Subindo aplicações..."
docker compose up -d
wait_healthy portal-nextcloud
wait_healthy portal-foxdesk

if [[ -x "$ROOT/scripts/configure-foxdesk-email-ptbr.sh" ]]; then
  echo "[restore] Reaplicando padronização pt-BR dos e-mails do FoxDesk..."
  PORTAL_ROOT="$ROOT" "$ROOT/scripts/configure-foxdesk-email-ptbr.sh"
fi

docker exec -u www-data portal-nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || true

if [[ "$skip_final_healthcheck" == "1" ]]; then
  echo "[restore] Dados restaurados. Healthcheck final adiado para depois da configuração de DNS/HTTPS."
else
  echo "[restore] Validando serviço restaurado..."
  if ! "$ROOT/scripts/healthcheck.sh"; then
    echo "ERRO: dados foram restaurados, mas o healthcheck final falhou. Revise o portal antes de liberar uso." >&2
    exit 3
  fi
  echo "[restore] Restauração concluída e validada."
fi
