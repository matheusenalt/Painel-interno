#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -d .git ]] || ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "[INFO] histórico Git ainda não possui commits; verificação de e-mail será feita após o primeiro commit."
  exit 0
fi

bad=0
while IFS= read -r email; do
  [[ -n "$email" ]] || continue
  if [[ "$email" != *@users.noreply.github.com ]]; then
    printf '[FALHA] e-mail de commit não é noreply do GitHub: %s\n' "$email" >&2
    bad=1
  fi
done < <(git log --format='%ae' | sort -u)

(( bad == 0 )) || exit 1

echo "[OK] autores dos commits usam endereço @users.noreply.github.com."
