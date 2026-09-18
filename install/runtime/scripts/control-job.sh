#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${PORTAL_ROOT:-/opt/portal-interno}"
action="${1:-}"
archive="${2:-}"
LOCK=/run/portal-interno-maintenance.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "ERRO: outra operação de backup/restauração está em andamento." >&2
  exit 75
fi
export PORTAL_LOCK_HELD=1
case "$action" in
  backup) exec "$ROOT/scripts/backup.sh" ;;
  restore)
    [[ -n "$archive" && -f "$archive" ]] || { echo "ERRO: arquivo de restauração não encontrado." >&2; exit 2; }
    echo "[controle] Pré-validando arquivo antes do snapshot de segurança..."
    if [[ -f "$archive.sha256" ]]; then
      (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256") >/dev/null
      echo "[controle] SHA-256 externo: OK"
    fi
    tar -tzf "$archive" >/dev/null
    echo "[controle] Contêiner gzip/tar: OK"
    echo "[controle] Criando snapshot de segurança antes da restauração..."
    "$ROOT/scripts/backup.sh"
    echo "[controle] Snapshot pré-restauração concluído. Iniciando rollback..."
    exec "$ROOT/scripts/restore.sh" --yes "$archive"
    ;;
  *) echo "ERRO: ação inválida." >&2; exit 2 ;;
esac
