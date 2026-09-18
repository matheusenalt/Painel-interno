#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "Uso: $0 VERSAO_FOXDESK (ex.: VERSAO_EXATA_APROVADA)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERRO: curl não encontrado." >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERRO: sha256sum não encontrado." >&2; exit 2; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
url="https://github.com/lukashanes/foxdesk/archive/refs/tags/v${VERSION}.tar.gz"

echo "Baixando tarball oficial da tag v${VERSION}..."
curl -fL --retry 4 --retry-delay 3 "$url" -o "$tmp"

echo
echo "SHA-256 calculado:"
sha256sum "$tmp" | awk '{print $1}'
echo
echo "Registre esse valor somente depois de validar que a versão/origem são as aprovadas para o ambiente."
