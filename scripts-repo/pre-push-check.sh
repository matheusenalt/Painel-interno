#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[1/8] Varredura de segredos..."
./scripts-repo/scan-secrets.sh

echo "[2/8] Sanitização para repositório público..."
python3 ./scripts-repo/check-public-sanitization.py

echo "[3/8] Privacidade do histórico Git..."
./scripts-repo/check-git-author-email.sh

if [[ -n "${PUBLIC_DENYLIST_FILE:-}" ]]; then
  echo "      denylist externa..."
  ./scripts-repo/check-denylist.sh "$PUBLIC_DENYLIST_FILE"
else
  echo "      INFO: PUBLIC_DENYLIST_FILE não definido; rode check-denylist.sh manualmente antes da publicação."
fi

echo "[4/8] Sintaxe Bash..."
while IFS= read -r -d '' f; do
  bash -n "$f"
done < <(find . -type f -name '*.sh' -print0)

echo "[5/8] JSON de exemplo..."
python3 - <<'PY'
import json
from pathlib import Path
for p in [Path('install/config/portal.json.example'), Path('install/config/team.json.example')]:
    json.loads(p.read_text())
    print(f'  OK: {p}')
PY

echo "[6/8] Python..."
while IFS= read -r -d '' f; do
  python3 -m py_compile "$f"
done < <(find . -type f -name '*.py' -print0)
find . -type d -name '__pycache__' -prune -exec rm -rf {} +

echo "[7/8] PHP..."
if command -v php >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    php -l "$f" >/dev/null
  done < <(find . -type f -name '*.php' -print0)
else
  echo "  AVISO: php não encontrado; lint PHP foi pulado."
fi

echo "[8/8] Configurações locais proibidas..."
if find install/config -maxdepth 1 -type f \( -name 'portal.json' -o -name 'team.json' \) -print -quit | grep -q .; then
  echo "ERRO: configuração real encontrada em install/config/." >&2
  exit 1
fi

echo "[OK] Repositório passou nas verificações locais pré-push."
