#!/usr/bin/env python3
import datetime as dt
import grp
import json
import os
from pathlib import Path
import re
import shutil
import socketserver
import subprocess
import threading

ROOT = Path('/opt/portal-interno')
SOCKET = Path('/run/portal-control/control.sock')
STATE_DIR = Path('/var/lib/portal-control')
LOG_DIR = Path('/var/log/portal-control')
INBOX = Path(os.environ.get('RESTORE_INBOX', '/srv/portal-restore-inbox'))
BACKUP_MODE = os.environ.get('BACKUP_MODE', 'pull')
if os.environ.get('BACKUP_DEST'):
    BACKUP_ROOT = Path(os.environ['BACKUP_DEST'])
elif BACKUP_MODE == 'pull':
    BACKUP_ROOT = Path(os.environ.get('BACKUP_EXPORT_ROOT', '/srv/portal-backup-sftp')) / 'files'
else:
    BACKUP_ROOT = Path('/mnt/backup-portal')
GROUP = 'portalctl'
NAME_RE = re.compile(r'^portal(?:-weekly)?-[0-9]{8}-[0-9]{6}\.tar\.gz$')
UPLOAD_RE = re.compile(r'^restore-[a-f0-9]{24}\.tar\.gz$')
state_lock = threading.Lock()

def now(): return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec='seconds')
def state_path(): return STATE_DIR/'last-job.json'
def write_state(data):
    tmp = STATE_DIR/'.last-job.json.tmp'
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    os.chmod(tmp, 0o640)
    os.replace(tmp, state_path())
def read_state():
    try: return json.loads(state_path().read_text())
    except Exception: return None
def log_tail(path, max_bytes=12000):
    try:
        with open(path, 'rb') as f:
            f.seek(0, os.SEEK_END); n=f.tell(); f.seek(max(0,n-max_bytes)); return f.read().decode('utf-8','replace')[-12000:]
    except Exception: return ''
def reconcile_state():
    s = read_state()
    if s and s.get('status') in ('queued','running'):
        s['status']='failed'; s['finished_at']=now(); s['message']='Serviço de controle reiniciado durante a operação; valide o estado do portal e o log.'; write_state(s)

def cleanup_stale_staging(max_age_days=7):
    try:
        cutoff=dt.datetime.now().timestamp()-(max_age_days*86400)
        if not INBOX.is_dir(): return
        for f in INBOX.iterdir():
            if f.is_file() and (UPLOAD_RE.fullmatch(f.name) or f.name.endswith('.tar.gz.sha256')) and f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)
    except Exception:
        pass

def list_backups():
    out=[]
    for kind in ('daily','weekly'):
        d=BACKUP_ROOT/kind
        if not d.is_dir(): continue
        for f in d.iterdir():
            if not f.is_file() or not NAME_RE.match(f.name): continue
            st=f.stat(); out.append({'kind':kind,'name':f.name,'size':st.st_size,'mtime':int(st.st_mtime),'has_checksum':Path(str(f)+'.sha256').is_file()})
    out.sort(key=lambda x:x['mtime'], reverse=True)
    return out

def ensure_idle():
    s=read_state()
    if s and s.get('status') in ('queued','running'):
        raise ValueError('Já existe uma operação de backup/restauração em andamento.')

def spawn_job(action, archive=None, display_name=None, cleanup_upload=False):
    with state_lock:
        ensure_idle()
        jid=dt.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+os.urandom(3).hex()
        log=LOG_DIR/f'{jid}.log'
        cmd=[str(ROOT/'scripts/control-job.sh'), action]
        if archive is not None: cmd.append(str(archive))
        state={'id':jid,'action':action,'status':'queued','started_at':now(),'finished_at':None,'message':display_name or '', 'log':str(log)}
        write_state(state)
        lf=open(log,'ab', buffering=0)
        proc=subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, close_fds=True, start_new_session=True, env={**os.environ,'PORTAL_ROOT':str(ROOT)})
        state['status']='running'; state['pid']=proc.pid; write_state(state)
        def waiter():
            rc=proc.wait(); lf.close()
            with state_lock:
                current=read_state() or state
                current['status']='success' if rc==0 else 'failed'; current['finished_at']=now(); current['exit_code']=rc
                current['message'] = ('Operação concluída.' if rc==0 else 'Operação falhou; revise o log.')
                write_state(current)
            if cleanup_upload and rc==0 and archive is not None:
                try: Path(archive).unlink(missing_ok=True); Path(str(archive)+'.sha256').unlink(missing_ok=True)
                except Exception: pass
        threading.Thread(target=waiter, daemon=True).start()
        return state

def resolve_local(kind,name):
    if kind not in ('daily','weekly') or not NAME_RE.fullmatch(name): raise ValueError('Backup local inválido.')
    base=(BACKUP_ROOT/kind).resolve(); f=(base/name).resolve()
    if f.parent != base or not f.is_file(): raise ValueError('Backup local não encontrado.')
    return f

def stage_local_backup(source):
    """Mantém o snapshot selecionado vivo mesmo se o pré-backup acionar retenção."""
    INBOX.mkdir(parents=True, exist_ok=True)
    staged = INBOX / ('restore-' + os.urandom(12).hex() + '.tar.gz')
    try:
        os.link(source, staged)
    except OSError:
        shutil.copy2(source, staged)
    os.chmod(staged, 0o660)
    sidecar = Path(str(source) + '.sha256')
    if sidecar.is_file():
        raw = sidecar.read_text(errors='replace')
        m = re.search(r'\b([a-fA-F0-9]{64})\b', raw)
        if not m:
            staged.unlink(missing_ok=True)
            raise ValueError('Checksum do backup local é inválido.')
        Path(str(staged) + '.sha256').write_text(m.group(1).lower() + '  ' + staged.name + '\n')
        os.chmod(Path(str(staged) + '.sha256'), 0o660)
    return staged

def resolve_upload(name):
    if not UPLOAD_RE.fullmatch(name): raise ValueError('Arquivo de staging inválido.')
    base=INBOX.resolve(); f=(base/name).resolve()
    if f.parent != base or not f.is_file(): raise ValueError('Backup enviado não encontrado.')
    return f

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            raw=self.rfile.readline(65536)
            if not raw: return
            req=json.loads(raw.decode('utf-8'))
            action=req.get('action')
            if action=='status':
                s=read_state()
                if s: s={**s,'log_tail':log_tail(s.get('log',''))}
                data={'ok':True,'job':s}
            elif action=='list_backups': data={'ok':True,'backups':list_backups()}
            elif action=='start_backup': data={'ok':True,'job':spawn_job('backup')}
            elif action=='start_restore':
                source=req.get('source'); name=str(req.get('name',''))
                if source=='local':
                    original=resolve_local(str(req.get('kind','')),name); f=stage_local_backup(original); cleanup=True; label=original.name
                elif source=='upload':
                    f=resolve_upload(name); cleanup=True; label=str(req.get('original_name') or name)[:180]
                else: raise ValueError('Origem de restauração inválida.')
                try:
                    data={'ok':True,'job':spawn_job('restore',f,label,cleanup)}
                except Exception:
                    if cleanup and source=='local':
                        Path(f).unlink(missing_ok=True); Path(str(f)+'.sha256').unlink(missing_ok=True)
                    raise
            else: raise ValueError('Ação não permitida.')
        except Exception as e: data={'ok':False,'error':str(e)}
        self.wfile.write((json.dumps(data,ensure_ascii=False)+'\n').encode('utf-8'))

class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads=True

def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True); LOG_DIR.mkdir(parents=True, exist_ok=True); SOCKET.parent.mkdir(parents=True, exist_ok=True)
    reconcile_state(); cleanup_stale_staging()
    try: SOCKET.unlink()
    except FileNotFoundError: pass
    with Server(str(SOCKET), Handler) as srv:
        gid=grp.getgrnam(GROUP).gr_gid; os.chown(SOCKET,0,gid); os.chmod(SOCKET,0o660)
        srv.serve_forever(poll_interval=.5)
if __name__=='__main__': main()
