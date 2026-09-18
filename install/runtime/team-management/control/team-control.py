#!/usr/bin/env python3
import base64
import datetime as dt
import grp
import json
import os
from pathlib import Path
import re
import secrets
import socketserver
import subprocess
import threading

SOCKET = Path('/run/portal-control/team.sock')
CONFIG = Path('/etc/portal-interno/team.json')
CREDENTIALS = Path('/root/portal-credenciais-equipe.txt')
AUDIT = Path('/var/log/team-management-actions.jsonl')
GROUP = 'portalctl'
UID_RE = re.compile(r'^[a-z0-9][a-z0-9._-]{2,31}$')
EMAIL_RE = re.compile(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
lock = threading.Lock()


def now():
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec='seconds')


def load_config():
    data = json.loads(CONFIG.read_text(encoding='utf-8'))
    em = data.get('employee_management') or {}
    sectors = em.get('allowed_sectors') or []
    parsed = {}
    for row in sectors:
        sid = str(row.get('id', '')).strip()
        name = str(row.get('name', sid)).strip()
        if not sid or sid == 'admin' or not re.fullmatch(r'[a-z0-9._-]+', sid):
            raise ValueError(f'Setor inválido no config: {sid!r}')
        parsed[sid] = name or sid
    if not parsed:
        raise ValueError('Nenhum setor permitido em employee_management.allowed_sectors.')
    return data, em, parsed


def run(cmd, *, env=None, timeout=60, check=True):
    p = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=(os.environ | (env or {})),
        timeout=timeout,
    )
    if check and p.returncode != 0:
        msg = (p.stderr or p.stdout or 'comando falhou').strip()
        raise RuntimeError(msg[-2000:])
    return p


def occ(args, *, env=None, check=True):
    env_args = [item for kv in (env or {}).items() for item in ('-e', f'{kv[0]}={kv[1]}')]
    return run(['docker', 'exec', '-u', 'www-data', *env_args, 'portal-nextcloud', 'php', 'occ', *list(args)], check=check)


def occ_json(args):
    p = occ(list(args) + ['--output=json'])
    try:
        return json.loads(p.stdout or '{}')
    except Exception as e:
        raise RuntimeError(f'Resposta JSON inválida do Nextcloud: {e}')


def container_env(container, key):
    p = run(['docker', 'inspect', '-f', '{{range .Config.Env}}{{println .}}{{end}}', container])
    prefix = key + '='
    for line in p.stdout.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):]
    return ''


def fox_db():
    name = container_env('portal-foxdesk-db', 'MARIADB_DATABASE')
    user = container_env('portal-foxdesk-db', 'MARIADB_USER')
    password = container_env('portal-foxdesk-db', 'MARIADB_PASSWORD')
    if not name or not user or not password:
        raise RuntimeError('Não consegui obter as credenciais internas do banco FoxDesk.')
    return name, user, password


def fox_sql(sql):
    name, user, password = fox_db()
    p = run([
        'docker', 'exec', '-e', f'MYSQL_PWD={password}', 'portal-foxdesk-db',
        'mariadb', '--batch', '--skip-column-names', f'-u{user}', name, '-e', sql,
    ])
    return p.stdout.strip()


def b64(value):
    return base64.b64encode(value.encode()).decode()


def fox_user_by_email(email):
    if not email:
        return None
    e = b64(email)
    row = fox_sql(
        "SELECT id,role,is_active FROM users "
        "WHERE (LOWER(CONVERT(email USING utf8mb4)) COLLATE utf8mb4_bin)=(LOWER(CONVERT(FROM_BASE64('%s') USING utf8mb4)) COLLATE utf8mb4_bin) LIMIT 1;" % e
    )
    if not row:
        return None
    parts = row.split('\t')
    return {
        'id': int(parts[0]),
        'role': parts[1] if len(parts) > 1 else '',
        'is_active': (parts[2] == '1') if len(parts) > 2 else True,
    }


def fox_deactivate_by_email(email):
    user = fox_user_by_email(email)
    if not user:
        return False
    fox_sql(f"UPDATE users SET is_active=0 WHERE id={int(user['id'])};")
    return True


def fox_create(name, email, password):
    if fox_user_by_email(email):
        raise ValueError('Já existe uma conta no FoxDesk com esse e-mail.')
    first = name.split(' ', 1)[0]
    last = name.split(' ', 1)[1] if ' ' in name else 'Usuario'
    p = run([
        'docker', 'exec', '-e', f'FOXDESK_USER_PASSWORD={password}', 'portal-foxdesk',
        'php', '-r', 'echo password_hash(getenv("FOXDESK_USER_PASSWORD"), PASSWORD_DEFAULT);',
    ])
    h = p.stdout.strip()
    if not h:
        raise RuntimeError('Falha ao gerar hash da senha FoxDesk.')
    sql = (
        "INSERT INTO users (email,password,first_name,last_name,role,is_active,language,created_at) VALUES ("
        f"CONVERT(FROM_BASE64('{b64(email)}') USING utf8mb4),"
        f"CONVERT(FROM_BASE64('{b64(h)}') USING utf8mb4),"
        f"CONVERT(FROM_BASE64('{b64(first)}') USING utf8mb4),"
        f"CONVERT(FROM_BASE64('{b64(last)}') USING utf8mb4),'agent',1,'pt-BR',NOW());"
    )
    fox_sql(sql)
    created = fox_user_by_email(email)
    if not created:
        raise RuntimeError('A conta FoxDesk não apareceu após a criação.')
    return created


def fox_update_identity(user_id, name, email):
    first = name.split(' ', 1)[0]
    last = name.split(' ', 1)[1] if ' ' in name else 'Usuario'
    fox_sql(
        "UPDATE users SET "
        f"email=CONVERT(FROM_BASE64('{b64(email)}') USING utf8mb4),"
        f"first_name=CONVERT(FROM_BASE64('{b64(first)}') USING utf8mb4),"
        f"last_name=CONVERT(FROM_BASE64('{b64(last)}') USING utf8mb4) "
        f"WHERE id={int(user_id)};"
    )


def audit(actor, action, target, details=None):
    entry = {
        'time': now(),
        'actor': actor,
        'action': action,
        'target': target,
        'details': details or {},
    }
    AUDIT.parent.mkdir(parents=True, exist_ok=True)
    with AUDIT.open('a', encoding='utf-8') as f:
        f.write(json.dumps(entry, ensure_ascii=False) + '\n')
    os.chmod(AUDIT, 0o640)


def append_credentials(line):
    CREDENTIALS.parent.mkdir(parents=True, exist_ok=True)
    with CREDENTIALS.open('a', encoding='utf-8') as f:
        f.write(line.rstrip() + '\n')
    os.chmod(CREDENTIALS, 0o600)


def save_create_credentials(name, uid, nc_pass, email='', fox_pass=''):
    line = f"{now()} | {name} | Nextcloud: {uid} | senha: {nc_pass}"
    if email and fox_pass:
        line += f" | FoxDesk: {email} | senha: {fox_pass}"
    else:
        line += " | FoxDesk: pendente (sem e-mail)"
    append_credentials(line)


def save_fox_credentials(name, uid, email, fox_pass):
    append_credentials(
        f"{now()} | {name} | Nextcloud: {uid} | FoxDesk criado: {email} | senha temporária: {fox_pass}"
    )


def password():
    # Senha temporária padronizada opcional. Se não estiver definida, mantém geração aleatória.
    _, em, _ = load_config()
    fixed = str(em.get('temporary_password') or '').strip()
    if fixed:
        return fixed
    return secrets.token_urlsafe(14) + secrets.choice('!@#%')


def normalize_email(email, *, allow_blank=False):
    email = str(email or '').strip().lower()
    if not email and allow_blank:
        return ''
    if not EMAIL_RE.fullmatch(email):
        raise ValueError('E-mail inválido.')
    return email


def validate_person(uid, name, email, sector, sectors):
    uid = uid.strip().lower()
    name = ' '.join(name.strip().split())
    email = normalize_email(email, allow_blank=True)
    sector = sector.strip()
    if uid == 'admin' or not UID_RE.fullmatch(uid):
        raise ValueError('Login inválido. Use 3–32 caracteres: letras minúsculas, números, ponto, _ ou -.')
    if len(name) < 2 or len(name) > 100:
        raise ValueError('Nome inválido.')
    if sector == 'admin' or sector not in sectors:
        raise ValueError('Setor não permitido.')
    return uid, name, email, sector


def group_map():
    data = occ_json(['group:list'])
    return data if isinstance(data, dict) else {}


def user_info(uid):
    p = occ(['user:info', '--output=json', uid], check=False)
    if p.returncode != 0:
        return None
    try:
        return json.loads(p.stdout)
    except Exception:
        return None


def protected_user(uid):
    if uid == 'admin' or not UID_RE.fullmatch(uid):
        raise ValueError('Usuário inválido.')
    info = user_info(uid)
    if info is None:
        raise ValueError('Usuário não encontrado no Nextcloud.')
    groups = set(info.get('groups') or [])
    if 'admin' in groups:
        raise ValueError('Contas administrativas são protegidas e não podem ser alteradas por este painel.')
    return info, groups


def list_employees():
    _, em, sectors = load_config()
    groups = group_map()
    admin_members = set(groups.get('admin') or [])
    ids = set()
    for sid in sectors:
        ids.update(groups.get(sid) or [])
    out = []
    for uid in sorted(ids):
        if uid in admin_members or uid == 'admin':
            continue
        info = user_info(uid) or {}
        memberships = info.get('groups') or []
        sector = next((sid for sid in sectors if sid in memberships), '')
        email = str(info.get('email') or '').strip()
        fox = fox_user_by_email(email) if email else None
        out.append({
            'uid': uid,
            'name': str(info.get('display_name') or uid),
            'email': email,
            'sector': sector,
            'sector_name': sectors.get(sector, sector),
            'enabled': bool(info.get('enabled', True)),
            'quota': str(info.get('quota') or em.get('personal_quota') or '2 GB'),
            'foxdesk': bool(fox),
            'foxdesk_role': (fox or {}).get('role', ''),
            'foxdesk_active': (fox or {}).get('is_active', False),
        })
    return out


def action_status():
    _, em, sectors = load_config()
    history = []
    try:
        lines = AUDIT.read_text(encoding='utf-8').splitlines()[-20:]
        for line in reversed(lines):
            try:
                history.append(json.loads(line))
            except Exception:
                pass
    except FileNotFoundError:
        pass
    return {
        'ok': True,
        'sectors': [{'id': k, 'name': v} for k, v in sectors.items()],
        'default_sector': em.get('default_sector', next(iter(sectors))),
        'personal_quota': em.get('personal_quota', '2 GB'),
        'employees': list_employees(),
        'history': history,
    }


def action_create(req):
    _, em, sectors = load_config()
    actor = str(req.get('actor') or 'unknown')[:64]
    uid, name, email, sector = validate_person(
        str(req.get('uid', '')),
        str(req.get('name', '')),
        str(req.get('email', '')),
        str(req.get('sector', '')),
        sectors,
    )
    if user_info(uid) is not None:
        raise ValueError('Esse login já existe no Nextcloud.')
    if email and fox_user_by_email(email):
        raise ValueError('Esse e-mail já existe no FoxDesk.')

    nc_pass = password()
    fd_pass = password() if email else ''
    created_nc = False
    try:
        occ(['user:add', '--password-from-env', f'--display-name={name}', f'--group={sector}', uid], env={'OC_PASS': nc_pass})
        created_nc = True
        if email:
            occ(['user:setting', uid, 'settings', 'email', email])
        occ(['user:setting', uid, 'files', 'quota', str(em.get('personal_quota', '2 GB'))])
        occ(['user:setting', uid, 'core', 'lang', str(em.get('language', 'pt_BR'))])
        if email:
            fox_create(name, email, fd_pass)
    except Exception:
        if created_nc:
            occ(['user:delete', uid], check=False)
        raise

    save_create_credentials(name, uid, nc_pass, email, fd_pass)
    audit(actor, 'create_employee', uid, {
        'name': name,
        'email': email,
        'sector': sector,
        'foxdesk': 'created' if email else 'pending_email',
    })
    return {
        'ok': True,
        'employee': {'uid': uid, 'name': name, 'email': email, 'sector': sector},
        'credentials': {
            'nextcloud_password': nc_pass,
            'foxdesk_password': fd_pass or None,
        },
        'foxdesk': 'created' if email else 'pending_email',
    }


def action_email(req):
    actor = str(req.get('actor') or 'unknown')[:64]
    uid = str(req.get('uid') or '').strip().lower()
    new_email = normalize_email(req.get('email'), allow_blank=False)
    info, _ = protected_user(uid)
    name = str(info.get('display_name') or uid)
    old_email = str(info.get('email') or '').strip().lower()

    old_fox = fox_user_by_email(old_email) if old_email else None
    new_fox = fox_user_by_email(new_email)

    if new_fox and (not old_fox or int(new_fox['id']) != int(old_fox['id'])):
        raise ValueError('Esse e-mail já pertence a outra conta no FoxDesk.')

    created_fox = False
    updated_fox = False
    fd_pass = ''

    # Primeiro atualiza o Nextcloud. Se o FoxDesk falhar, tentamos reverter o e-mail do Nextcloud.
    if old_email != new_email:
        occ(['user:setting', uid, 'settings', 'email', new_email])

    try:
        if old_fox:
            if old_email != new_email:
                fox_update_identity(old_fox['id'], name, new_email)
                updated_fox = True
        elif not new_fox:
            fd_pass = password()
            fox_create(name, new_email, fd_pass)
            created_fox = True
            save_fox_credentials(name, uid, new_email, fd_pass)
        # Se new_fox existe e é o mesmo old_fox, já está vinculado; não mexe em perfil/senha.
    except Exception:
        if old_email != new_email:
            occ(['user:setting', uid, 'settings', 'email', old_email], check=False)
        raise

    audit(actor, 'save_email', uid, {
        'from': old_email,
        'to': new_email,
        'foxdesk': 'created' if created_fox else ('updated' if updated_fox else 'already_linked'),
    })
    return {
        'ok': True,
        'uid': uid,
        'email': new_email,
        'foxdesk': 'created' if created_fox else ('updated' if updated_fox else 'already_linked'),
        'credentials': {'foxdesk_password': fd_pass or None},
        'message': (
            'E-mail salvo no Nextcloud e conta FoxDesk criada.' if created_fox else
            'E-mail atualizado no Nextcloud e na conta FoxDesk existente.' if updated_fox else
            'E-mail salvo. A conta FoxDesk já estava vinculada.'
        ),
    }


def action_sector(req):
    _, _, sectors = load_config()
    actor = str(req.get('actor') or 'unknown')[:64]
    uid = str(req.get('uid') or '').strip().lower()
    sector = str(req.get('sector') or '').strip()
    if sector == 'admin' or sector not in sectors:
        raise ValueError('Setor não permitido.')
    info, groups = protected_user(uid)
    old = next((sid for sid in sectors if sid in groups), '')
    for sid in sectors:
        if sid != sector and sid in groups:
            occ(['group:removeuser', sid, uid])
    if sector not in groups:
        occ(['group:adduser', sector, uid])
    audit(actor, 'change_sector', uid, {'from': old, 'to': sector})
    return {'ok': True, 'uid': uid, 'sector': sector, 'sector_name': sectors[sector]}


def action_offboard(req):
    _, _, sectors = load_config()
    actor = str(req.get('actor') or 'unknown')[:64]
    uid = str(req.get('uid') or '').strip().lower()
    confirm = str(req.get('confirm') or '').strip()
    if actor == uid:
        raise ValueError('Você não pode desligar a própria conta por este painel.')
    info, groups = protected_user(uid)
    if confirm != f'EXCLUIR {uid}':
        raise ValueError(f'Confirmação inválida. Digite exatamente: EXCLUIR {uid}')
    email = str(info.get('email') or '').strip().lower()
    name = str(info.get('display_name') or uid)
    fox_disabled = False
    if email:
        fox_disabled = fox_deactivate_by_email(email)

    p = occ(['user:delete', uid], check=False)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or 'Falha ao excluir usuário do Nextcloud.').strip())

    audit(actor, 'offboard_employee', uid, {
        'name': name,
        'email': email,
        'nextcloud': 'deleted',
        'foxdesk': 'disabled' if fox_disabled else 'not_found',
        'previous_sectors': sorted([g for g in groups if g in sectors]),
    })
    return {
        'ok': True,
        'uid': uid,
        'name': name,
        'nextcloud': 'deleted',
        'foxdesk': 'disabled' if fox_disabled else 'not_found',
        'message': (
            'Conta Nextcloud excluída. A conta FoxDesk foi desativada para preservar o histórico de chamados.'
            if fox_disabled else
            'Conta Nextcloud excluída. Não havia conta FoxDesk vinculada a esse e-mail.'
        ),
    }


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            raw = self.rfile.readline(65536)
            if not raw:
                return
            req = json.loads(raw.decode('utf-8'))
            action = req.get('action')
            with lock:
                if action == 'status':
                    data = action_status()
                elif action == 'create_employee':
                    data = action_create(req)
                elif action == 'save_email':
                    data = action_email(req)
                elif action == 'change_sector':
                    data = action_sector(req)
                elif action == 'offboard_employee':
                    data = action_offboard(req)
                else:
                    raise ValueError('Ação não permitida.')
        except Exception as e:
            data = {'ok': False, 'error': str(e)}
        self.wfile.write((json.dumps(data, ensure_ascii=False) + '\n').encode('utf-8'))


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


if __name__ == '__main__':
    if not CONFIG.is_file():
        raise SystemExit(f'Config ausente: {CONFIG}')
    SOCKET.parent.mkdir(parents=True, exist_ok=True)
    try:
        SOCKET.unlink()
    except FileNotFoundError:
        pass
    with Server(str(SOCKET), Handler) as srv:
        gid = grp.getgrnam(GROUP).gr_gid
        os.chown(SOCKET, 0, gid)
        os.chmod(SOCKET, 0o660)
        srv.serve_forever(poll_interval=.5)
