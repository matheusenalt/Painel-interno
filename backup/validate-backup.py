#!/usr/bin/env python3
import argparse, hashlib, os, shutil, sys, tarfile
from pathlib import Path, PurePosixPath

ALLOWED={'nextcloud.sql','foxdesk.sql','nextcloud-volume.tar','foxdesk-volume.tar','portal-config.tar.gz','host-config.tar.gz','manifest.sha256'}
REQUIRED={'nextcloud.sql','foxdesk.sql','nextcloud-volume.tar','foxdesk-volume.tar'}

def normalize(name):
    while name.startswith('./'): name=name[2:]
    if name in ('','.'): return ''
    p=PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or len(p.parts)!=1: raise ValueError(f'entrada externa insegura: {name}')
    return p.name
def hash_file(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()
def check_inner(path):
    with tarfile.open(path,'r:') as t:
        for m in t.getmembers():
            p=PurePosixPath(m.name)
            if p.is_absolute() or '..' in p.parts: raise ValueError(f'caminho inseguro em {path.name}: {m.name}')
            if not (m.isfile() or m.isdir() or m.issym() or m.islnk()): raise ValueError(f'tipo especial não permitido em {path.name}: {m.name}')
            if m.issym() or m.islnk():
                q=PurePosixPath(m.linkname)
                if q.is_absolute() or '..' in q.parts: raise ValueError(f'link inseguro em {path.name}: {m.name} -> {m.linkname}')
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('archive'); ap.add_argument('dest'); args=ap.parse_args()
    archive=Path(args.archive); dest=Path(args.dest); dest.mkdir(parents=True, exist_ok=True)
    seen={}; total=0
    with tarfile.open(archive,'r:gz') as t:
        for m in t.getmembers():
            n=normalize(m.name)
            if not n: continue
            if n not in ALLOWED: raise ValueError(f'arquivo inesperado no backup: {n}')
            if not m.isfile(): raise ValueError(f'entrada não regular no backup: {n}')
            if n in seen: raise ValueError(f'entrada duplicada no backup: {n}')
            seen[n]=m; total += m.size
        missing=REQUIRED-set(seen)
        if missing: raise ValueError('backup incompleto; faltando: '+', '.join(sorted(missing)))
        free=shutil.disk_usage(dest).free
        reserve=2*1024**3
        if total+reserve>free: raise ValueError(f'espaço insuficiente para staging: precisa ~{(total+reserve)/1024**3:.1f} GiB, livre {free/1024**3:.1f} GiB')
        for n,m in seen.items():
            src=t.extractfile(m)
            if src is None: raise ValueError(f'não foi possível ler {n}')
            out=dest/n
            with open(out,'wb') as f: shutil.copyfileobj(src,f,1024*1024)
            os.chmod(out,0o600)
    manifest=dest/'manifest.sha256'
    if manifest.exists():
        checked=set()
        for line in manifest.read_text(errors='strict').splitlines():
            if not line.strip(): continue
            parts=line.split()
            if len(parts)<2 or len(parts[0])!=64: raise ValueError('manifest.sha256 inválido')
            name=parts[-1].lstrip('*')
            if name not in ALLOWED-{'manifest.sha256'} or not (dest/name).is_file(): raise ValueError(f'manifest referencia arquivo inválido: {name}')
            if hash_file(dest/name).lower()!=parts[0].lower(): raise ValueError(f'checksum interno falhou: {name}')
            checked.add(name)
        expected={'nextcloud.sql','foxdesk.sql','nextcloud-volume.tar','foxdesk-volume.tar'}
        if not expected.issubset(checked): raise ValueError('manifest.sha256 incompleto; faltam checksums obrigatórios')
        print('[validate] manifest interno: OK')
    else:
        print('[validate] AVISO: backup legado sem manifest interno; usando validação estrutural.', file=sys.stderr)
    check_inner(dest/'nextcloud-volume.tar'); check_inner(dest/'foxdesk-volume.tar')
    for cfg_name in ('portal-config.tar.gz','host-config.tar.gz'):
        cfg=dest/cfg_name
        if not cfg.exists(): continue
        with tarfile.open(cfg,'r:gz') as t:
            for m in t.getmembers():
                p=PurePosixPath(m.name)
                if p.is_absolute() or '..' in p.parts: raise ValueError(f'caminho inseguro em {cfg_name}: {m.name}')
                if not (m.isfile() or m.isdir()): raise ValueError(f'tipo especial/link não permitido em {cfg_name}: {m.name}')
    print('[validate] estrutura externa e volumes internos: OK')
if __name__=='__main__':
    try: main()
    except Exception as e:
        print(f'ERRO: {e}', file=sys.stderr); sys.exit(1)
