#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$ROOT/config/portal.json"
PROFILE="${1:-homologacao}"

err(){ printf '[ERRO] %s\n' "$*" >&2; errors=$((errors+1)); }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[AVISO] %s\n' "$*"; }
errors=0

command -v jq >/dev/null 2>&1 || { echo "Instale jq para validar: sudo apt install jq" >&2; exit 2; }
jq empty "$CFG" >/dev/null || { echo "JSON inválido: $CFG" >&2; exit 2; }
[[ "$PROFILE" == "homologacao" || "$PROFILE" == "prod" ]] || { echo "Uso: $0 [homologacao|prod]" >&2; exit 2; }

for expr in '.company.name' '.company.timezone' '.versions.nextcloud' '.versions.mariadb' '.versions.redis' '.versions.foxdesk' '.security.initial_user_password' '.backup.mode'; do
  v="$(jq -r "$expr // empty" "$CFG")"
  [[ -n "$v" ]] || err "Campo obrigatório ausente: $expr"
done

# A edição pública usa placeholders de versão para evitar defaults desatualizados.
for key in nextcloud mariadb redis foxdesk; do
  v="$(jq -r --arg key "$key" '.versions[$key] // empty' "$CFG")"
  [[ "$v" != DEFINA_* && "$v" != *'.x'* && "$v" != *'x-'* ]] \
    || err "versions.$key ainda contém valor de exemplo; informe uma versão/tag exata aprovada."
done

# Em produção, fixe a integridade do tarball do FoxDesk.
foxdesk_sha256="$(jq -r '.versions.foxdesk_sha256 // empty' "$CFG")"
if [[ "$PROFILE" == "prod" ]]; then
  [[ "$foxdesk_sha256" =~ ^[A-Fa-f0-9]{64}$ ]] \
    || err "versions.foxdesk_sha256 deve conter 64 caracteres hexadecimais em produção. Veja docs/FOXDESK-INTEGRIDADE.md no repositório."
  [[ "$foxdesk_sha256" != "SHA256_DA_VERSAO_FOXDESK_APROVADA_AQUI" ]] \
    || err "versions.foxdesk_sha256 ainda contém o placeholder do exemplo."
else
  [[ -z "$foxdesk_sha256" || "$foxdesk_sha256" =~ ^[A-Fa-f0-9]{64}$ ]] \
    || warn "versions.foxdesk_sha256 está preenchido, mas não possui formato SHA-256 válido."
fi

[[ "$(jq '[.users[].id] | length == (unique|length)' "$CFG")" == "true" ]] || err "Há logins duplicados em users[].id"

# Identidade dos usuários: login estável + nome completo.
# E-mail é opcional; quando informado, apenas validamos o formato.
while IFS= read -r row; do
  uid="$(jq -r '.id // empty' <<<"$row")"
  full_name="$(jq -r '.full_name // .display // empty' <<<"$row")"
  email="$(jq -r '.email // empty' <<<"$row")"
  foxdesk_role="$(jq -r '.foxdesk_role // "agent"' <<<"$row")"
  [[ -n "$full_name" ]] || err "Usuário $uid sem users[].full_name"
  [[ "$foxdesk_role" == "admin" || "$foxdesk_role" == "agent" ]] || err "foxdesk_role inválido para $uid: $foxdesk_role"
  if [[ -n "$email" ]]; then
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || err "E-mail inválido para $uid: $email"
  else
    warn "Usuário $uid sem e-mail (aceito; notificações/recuperação por e-mail ficam indisponíveis)"
  fi
done < <(jq -c '.users[]' "$CFG")

while IFS= read -r dup; do
  [[ -z "$dup" ]] || err "E-mail duplicado em users[]: $dup"
done < <(jq -r '[.users[] | (.email // "") | ascii_downcase | select(length > 0)] | sort | group_by(.)[] | select(length > 1) | .[0]' "$CFG")

[[ "$(jq '[.team_folders[].name] | length == (unique|length)' "$CFG")" == "true" ]] || err "Há Team Folders duplicadas"
[[ "$(jq '[.calendars[].uri] | length == (unique|length)' "$CFG")" == "true" ]] || err "Há URIs de calendário duplicadas"

mapfile -t groups < <(jq -r '.groups[]' "$CFG")
for uid in $(jq -r '.users[].id' "$CFG"); do
  while IFS= read -r g; do
    [[ " $([ ${#groups[@]} -gt 0 ] && printf '%s ' "${groups[@]}") " == *" $g "* ]] || err "Usuário $uid referencia grupo inexistente: $g"
  done < <(jq -r --arg u "$uid" '.users[] | select(.id==$u) | .groups[]' "$CFG")
done

while IFS= read -r g; do
  [[ "$g" == "admin" || " $([ ${#groups[@]} -gt 0 ] && printf '%s ' "${groups[@]}") " == *" $g "* ]] || err "Permissão de Team Folder referencia grupo inexistente: $g"
done < <(jq -r '.team_folders[].permissions | keys[]' "$CFG" | sort -u)

while IFS= read -r g; do
  [[ " $([ ${#groups[@]} -gt 0 ] && printf '%s ' "${groups[@]}") " == *" $g "* ]] || err "Calendário referencia grupo inexistente: $g"
done < <(jq -r '.calendars[].groups[]' "$CFG" | sort -u)


backup_mode="$(jq -r '.backup.mode // empty' "$CFG")"
[[ "$backup_mode" == "pull" || "$backup_mode" == "mount" ]] || err "backup.mode deve ser pull ou mount"
if [[ "$backup_mode" == "pull" ]]; then
  backup_user="$(jq -r '.backup.sftp_user // empty' "$CFG")"
  backup_root="$(jq -r '.backup.export_root // empty' "$CFG")"
  [[ "$backup_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || err "backup.sftp_user inválido"
  [[ "$backup_root" == /* ]] || err "backup.export_root deve ser caminho absoluto"
fi


restore_limit="$(jq -r '.backup.restore_upload_limit // "64G"' "$CFG")"
restore_inbox="$(jq -r '.backup.restore_inbox // "/srv/portal-restore-inbox"' "$CFG")"
restore_tmp="$(jq -r '.backup.restore_tmp // "/srv/portal-restore-tmp"' "$CFG")"
[[ "$restore_limit" =~ ^[1-9][0-9]*[MG]$ ]] || err "backup.restore_upload_limit deve ser algo como 16G/64G"
[[ "$restore_inbox" == /* && "$restore_inbox" != "/" ]] || err "backup.restore_inbox deve ser caminho absoluto não-raiz"
[[ "$restore_tmp" == /* && "$restore_tmp" != "/" ]] || err "backup.restore_tmp deve ser caminho absoluto não-raiz"
[[ "$restore_inbox" != "$restore_tmp" ]] || err "backup.restore_inbox e backup.restore_tmp precisam ser diferentes"

if [[ "$PROFILE" == "prod" ]]; then
  nc_domain="$(jq -r '.network.production.nextcloud_domain // empty' "$CFG")"
  fox_domain="$(jq -r '.network.production.foxdesk_domain // empty' "$CFG")"
  [[ "$nc_domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || err "Defina network.production.nextcloud_domain antes do perfil prod"
  [[ "$fox_domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || err "Defina network.production.foxdesk_domain antes do perfil prod"
fi

if (( errors > 0 )); then
  printf '\nConfiguração inválida: %d erro(s).\n' "$errors" >&2
  exit 1
fi
ok "portal.json válido para perfil $PROFILE"
printf 'Usuários: %s | Team Folders: %s | Calendários: %s | Links: %s\n' \
  "$(jq '.users|length' "$CFG")" "$(jq '.team_folders|length' "$CFG")" "$(jq '.calendars|length' "$CFG")" "$(jq '.external_links|length' "$CFG")"
