#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "ERRO: execute com sudo: sudo ./iniciar-do-zero.sh" >&2; exit 1; }
if [[ -e /opt/portal-interno/.env || -d /var/lib/docker/volumes/portal-nextcloud-app/_data ]]; then
  echo "ERRO: este host já parece possuir um Portal Interno. O script não apagará produção automaticamente." >&2
  echo "Se a intenção é migração/DR, use install-from-backup.sh em uma VPS limpa." >&2
  exit 1
fi
cat <<'MSG'
Este modo cria um ambiente NOVO a partir do portal.json local.
Ele NÃO restaura dados de um snapshot.
MSG
read -r -p "Digite INSTALAR para continuar: " confirm
[[ "$confirm" == "INSTALAR" ]] || { echo "Cancelado."; exit 1; }
exec "$HERE/install-portal.sh"
