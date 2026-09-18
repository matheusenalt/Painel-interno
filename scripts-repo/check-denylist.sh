#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENYLIST="${1:-${PUBLIC_DENYLIST_FILE:-}}"

if [[ -z "$DENYLIST" ]]; then
  echo "Uso: $0 /caminho/fora/do/repositorio/denylist.txt" >&2
  echo "ou: PUBLIC_DENYLIST_FILE=~/denylist.txt $0" >&2
  exit 2
fi

DENYLIST="${DENYLIST/#\~/$HOME}"
[[ -f "$DENYLIST" ]] || { echo "Denylist não encontrada: $DENYLIST" >&2; exit 2; }

cd "$ROOT"
if grep -rniF -f "$DENYLIST" . --exclude-dir=.git --exclude='*.zip' --exclude='*.gz' --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.webp'; then
  echo "[FALHA] denylist externa encontrou termos que precisam ser revisados." >&2
  exit 1
fi

echo "[OK] denylist externa não encontrou termos proibidos."
