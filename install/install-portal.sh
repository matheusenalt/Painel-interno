#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$HERE/runtime"
CFG="$HERE/config/portal.json"
[[ $EUID -eq 0 ]] || { echo "ERRO: execute com sudo: sudo ./install-portal.sh" >&2; exit 1; }
[[ -f "$CFG" ]] || { cat >&2 <<'MSG'
ERRO: install/config/portal.json não existe.
1) cp install/config/portal.json.example install/config/portal.json
2) Edite SOMENTE a cópia local.
3) Não faça commit dela; o .gitignore já a protege.
MSG
exit 1; }
if grep -qE 'SEU_DOMINIO_|NOME_DO_PORTAL_AQUI|NOME_COMPLETO_AQUI|DEFINA_FORA_DO_GIT|PASTA_COMPARTILHADA_EXEMPLO|AGENDA_DA_EQUIPE|SHA256_DA_VERSAO_FOXDESK_APROVADA_AQUI' "$CFG"; then
  echo "ERRO: portal.json ainda contém placeholders do exemplo. Preencha/remova os valores antes de instalar." >&2
  exit 1
fi
install -d -m 0755 "$RUNTIME/config"
install -m 0600 "$CFG" "$RUNTIME/config/portal.json"
PORTAL_CONFIG="$RUNTIME/config/portal.json" "$RUNTIME/install-portal-core.sh"
# Gestão de Equipe é opcional porque sua configuração contém dados/credenciais e é entregue fora do Git.
if [[ -f "$HERE/config/team.json" && -x /opt/portal-interno/team-management/install-team-management.sh ]]; then
  echo "[DR] Configuração segura de equipe encontrada; instalando módulo Gestão de Equipe..."
  TEAM_CONFIG_SRC="$HERE/config/team.json" /opt/portal-interno/team-management/install-team-management.sh
else
  echo "[DR] Gestão de Equipe não instalada automaticamente: install/config/team.json não foi fornecido."
fi
