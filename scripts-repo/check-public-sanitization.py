#!/usr/bin/env python3
from __future__ import annotations
from pathlib import Path
import ipaddress
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SKIP_SUFFIXES = {'.png','.jpg','.jpeg','.gif','.webp','.ico','.zip','.gz','.tar','.woff','.woff2','.ttf'}
EMAIL_RE = re.compile(r'(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})(?![A-Za-z0-9._%+-])')
IP_RE = re.compile(r'(?<![\d.])((?:\d{1,3}\.){3}\d{1,3})(?![\d.])')

DOC_NETS = [
    ipaddress.ip_network('192.0.2.0/24'),
    ipaddress.ip_network('198.51.100.0/24'),
    ipaddress.ip_network('203.0.113.0/24'),
]

problems: list[str] = []

for p in ROOT.rglob('*'):
    if not p.is_file() or '.git' in p.parts or p.suffix.lower() in SKIP_SUFFIXES:
        continue
    try:
        text = p.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    rel = p.relative_to(ROOT)

    for email in EMAIL_RE.findall(text):
        domain = email.rsplit('@',1)[1].lower()
        if domain.endswith('.invalid') or domain == 'openssh.com':
            continue
        problems.append(f'{rel}: e-mail literal possivelmente real: {email}')

    for raw in IP_RE.findall(text):
        try:
            ip = ipaddress.ip_address(raw)
        except ValueError:
            continue
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_unspecified or any(ip in net for net in DOC_NETS):
            continue
        problems.append(f'{rel}: IPv4 público literal possivelmente real: {raw}')

branding = ROOT / 'install/runtime/branding'
if branding.exists():
    unexpected = [p.name for p in branding.iterdir() if p.is_file() and p.name != 'README.md']
    if unexpected:
        problems.append('branding público contém arquivo(s) além do README: ' + ', '.join(sorted(unexpected)))

for forbidden in [ROOT/'docs/gestao', ROOT/'docs/private']:
    if forbidden.exists():
        problems.append(f'diretório interno presente: {forbidden.relative_to(ROOT)}')

if problems:
    print('[FALHA] revisão de sanitização pública encontrou possíveis vazamentos:', file=sys.stderr)
    for item in problems:
        print('  - ' + item, file=sys.stderr)
    sys.exit(1)

print('[OK] sanitização pública: sem e-mails reais, IPs públicos literais ou branding interno detectados.')
