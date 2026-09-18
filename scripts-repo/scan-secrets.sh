#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0

check(){
  local label="$1" regex="$2"
  shift 2
  if grep -RInE --binary-files=without-match --exclude-dir=.git "$@" "$regex" .; then
    echo "[FALHA] $label" >&2
    fail=1
  fi
}

check "chave privada" 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY'
check "possível segredo literal" '(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/._-]{16,}'
if find . -type f \( -name id_rsa -o -name id_ed25519 -o -name id_ecdsa \) -print -quit | grep -q .; then
  echo "[FALHA] arquivo de chave privada encontrado na árvore do repositório." >&2
  fail=1
fi

for f in install/config/portal.json install/config/team.json; do
  if [[ -f "$f" ]]; then
    echo "[FALHA] arquivo local sensível presente: $f" >&2
    fail=1
  fi
done

if (( fail == 0 )); then
  echo "[OK] varredura básica sem achados."
else
  exit 1
fi
