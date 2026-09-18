<div align="center">

# Portal Interno Self-Hosted

**Painel interno self-hosted para centralizar gestão, suporte, arquivos, chamados, usuários, backups e rotinas administrativas em um único ambiente.**

Desenvolvido para reduzir informações espalhadas entre diferentes ferramentas, melhorar o controle operacional e criar uma estrutura mais organizada, segura e fácil de administrar.

**Nextcloud + FoxDesk em Docker, com provisionamento automatizado, backup externo, restore e Disaster Recovery documentado.**

![status](https://img.shields.io/badge/status-baseline%20validado-2ea44f.svg?style=flat-square)
![portfolio](https://img.shields.io/badge/edi%C3%A7%C3%A3o-p%C3%BAblica%20sanitizada-6f42c1.svg?style=flat-square)
![nextcloud](https://img.shields.io/badge/Nextcloud-34.x-0082C9.svg?style=flat-square)
![foxdesk](https://img.shields.io/badge/FoxDesk-0.3.x-orange.svg?style=flat-square)
![docker](https://img.shields.io/badge/Docker-Compose-2496ED.svg?style=flat-square)
![backup](https://img.shields.io/badge/backup-pull%20SFTP-blueviolet.svg?style=flat-square)
![restore](https://img.shields.io/badge/restore-validado-2ea44f.svg?style=flat-square)

</div>

---

> 🔐 **Versão pública e sanitizada de um projeto real de infraestrutura.**  
> Nomes, domínios, endereços IP públicos, e-mails, credenciais, chaves, identidade visual e dados operacionais foram removidos ou substituídos por placeholders.

---

## 🎯 Sobre o projeto

Este repositório demonstra a construção de um **portal interno self-hosted** com foco em operação, continuidade e recuperação de desastre.

A solução combina:

- ☁️ **Nextcloud** para arquivos, calendários, base de conhecimento e colaboração;
- 🎫 **FoxDesk** para chamados e acompanhamento de demandas;
- 🐳 **Docker Compose** para isolamento e reprodutibilidade;
- 🌐 **Caddy** como reverse proxy com HTTPS;
- 💾 **backup automatizado** com checksum e cópia externa via SFTP;
- ♻️ **restore completo** de bancos, volumes e configurações;
- 🧪 **healthcheck e auditoria** pós-instalação/restore;
- 🛡️ **hardening básico** do host;
- 🧰 scripts para **reinstalação do zero ou recuperação por snapshot**.

O objetivo não é apenas "subir containers", mas manter um ambiente que possa ser **reconstruído, validado e transferido para outro técnico** com o mínimo de conhecimento prévio.

---

## 🧱 Arquitetura

```text
Internet
   │
   ▼
DNS + HTTPS
   │
   ▼
Caddy / Reverse Proxy
   │
   ├──────────────► Nextcloud ──► MariaDB
   │                    │
   │                    └──────► Redis
   │
   └──────────────► FoxDesk ───► MariaDB

Backup / DR
VPS
 │
 ├─ snapshot .tar.gz
 ├─ SHA-256
 │
 ▼
SFTP somente leitura
 │
 ▼
VM Debian de backup
 │
 ▼
HD externo
```

---

## ✨ O que está automatizado

| Área | Automação |
|---|---|
| Provisionamento | Instalação do host, Docker, containers e configuração inicial |
| Nextcloud | Apps, grupos, usuários, Team Folders, calendários e base de conhecimento |
| FoxDesk | Banco, usuário admin, status, prioridades, idioma e e-mails em pt-BR |
| Segurança | UFW, Fail2ban, serviços locais, permissões e validações |
| HTTPS | Caddy + reverse proxy após DNS estar pronto |
| Backup | Snapshot consistente, dumps SQL, volumes, manifest e SHA-256 |
| Cópia externa | Pull via SFTP somente leitura para VM/HD externo |
| Restore | Validação, snapshot pré-rollback, restauração e healthcheck final |
| DR | Instalação do zero **ou** reconstrução por backup |
| Operação | Healthcheck, auditoria e scripts de diagnóstico |

---

## 🧭 Dois caminhos de recuperação

### 🆕 1. Instalação do zero

Use quando não há snapshot para aproveitar ou quando o ambiente deve ser recriado com uma configuração nova.

```text
VPS limpa
   ↓
portal.json local
   ↓
install-portal.sh
   ↓
Nextcloud + FoxDesk
   ↓
HTTPS
   ↓
healthcheck
   ↓
backup inicial
```

Entrada principal:

```text
install/install-portal.sh
```

---

### ♻️ 2. Recuperação a partir de backup

Use quando existe um snapshot válido de um ambiente anterior.

```text
VPS limpa
   ↓
preparação do runtime
   ↓
validação .tar.gz + .sha256
   ↓
restore dos bancos e volumes
   ↓
subida dos serviços
   ↓
HTTPS
   ↓
healthcheck
```

Entrada principal:

```text
install/install-from-backup.sh
```

---

## 📁 Estrutura do repositório

```text
portal-interno-selfhosted/
├── README.md
├── SECURITY.md
├── CHANGELOG.md
├── VERSION
│
├── install/
│   ├── install-portal.sh
│   ├── install-from-backup.sh
│   ├── iniciar-do-zero.sh
│   ├── config/
│   │   ├── portal.json.example
│   │   └── team.json.example
│   └── runtime/
│       ├── compose.yaml
│       ├── control/
│       ├── cron/
│       ├── foxdesk/
│       ├── nextcloud/
│       ├── nextcloud-apps/
│       ├── scripts/
│       └── team-management/
│
├── backup/
│   ├── backup.sh
│   ├── restore.sh
│   ├── validate-backup.py
│   └── systemd/
│
├── backup-vm-host/
│   ├── portal-backup-pull.sh
│   ├── portal-backup-boot-run.sh
│   ├── portal-backup-host-run.sh
│   ├── timers/
│   └── WINDOWS.md
│
├── https/
├── healthcheck/
├── docs/
└── scripts-repo/
```

---

## ⚡ Pré-requisitos

Para implantação em uma VPS nova:

- Ubuntu Server **22.04 ou 24.04**;
- acesso `root` ou `sudo`;
- pelo menos **2 vCPU e ~4 GB de RAM** para laboratório;
- espaço em disco suficiente para dados + snapshots;
- dois domínios/subdomínios controlados pelo operador;
- portas 80/443 disponíveis para o proxy;
- Git, curl e conectividade com os repositórios necessários.

Para produção, revise os limites de memória, armazenamento, DNS, SMTP, retenção e políticas de segurança de acordo com o ambiente real.

---

## 🚀 Instalação rápida

Clone:

```bash
git clone https://github.com/SEU_USUARIO/portal-interno-selfhosted.git
cd portal-interno-selfhosted
```

Crie a configuração local:

```bash
cp install/config/portal.json.example install/config/portal.json
```

Edite **somente a cópia local** e nunca versione dados reais.

Depois:

```bash
cd install
sudo ./install-portal.sh
```

Ao final, configure HTTPS e valide o ambiente.

---

## 🌐 HTTPS

Depois que o DNS apontar para a VPS:

```bash
sudo /opt/portal-interno/scripts/configurar-https.sh
```

O script prepara o Caddy para publicar os dois backends que permanecem presos ao loopback.

---

## ✅ Healthcheck

Após instalação, atualização ou restore:

```bash
sudo /opt/portal-interno/scripts/healthcheck.sh
```

Também existe uma auditoria complementar:

```bash
sudo /opt/portal-interno/scripts/auditar-seguranca.sh
```

Entre outras coisas, as verificações cobrem:

- containers e health dos bancos;
- Redis;
- Nextcloud e `occ`;
- FoxDesk;
- apps obrigatórios;
- calendários e Team Folders;
- cron;
- controle de backup/restore;
- exportação SFTP;
- Caddy e HTTPS.

---

## 💾 Backup

Backup manual:

```bash
sudo /opt/portal-interno/scripts/backup.sh
```

O snapshot inclui o estado necessário para reconstrução e passa por validações de integridade.

A estratégia externa segue o modelo **pull-only**:

```text
VPS  ──SFTP read-only──►  VM de backup  ──►  HD externo
```

A VPS não recebe permissão para escrever diretamente na mídia externa.

---

## ♻️ Restore

Exemplo pelo terminal:

```bash
sudo /opt/portal-interno/scripts/restore.sh \
  /caminho/portal-AAAAMMDD-HHMMSS.tar.gz
```

O fluxo inclui:

1. validação do arquivo e checksum;
2. snapshot de segurança antes do rollback;
3. parada controlada dos serviços;
4. restauração de volumes;
5. recriação/importação dos bancos;
6. limpeza de cache/locks;
7. subida das aplicações;
8. healthcheck final.

O repositório também inclui um app administrativo local para backup/restore pelo Nextcloud.

---

## 🇧🇷 FoxDesk em pt-BR

A edição pública preserva a camada de padronização criada para os e-mails do FoxDesk.

Os fluxos tratados incluem:

- novo chamado;
- confirmação de recebimento;
- atribuição;
- novo comentário;
- mudança de status;
- redefinição de senha;
- boas-vindas;
- tarefa recorrente;
- alertas de cronômetro;
- lembretes de prazo.

O patch é reaplicado após restore para que um volume antigo não recoloque os templates originais em inglês.

---

## 🖥️ Host Linux e Windows para a VM de backup

O baseline principal usa um host Linux para controlar a VM de backup e os timers.

Também existe uma adaptação para Windows:

👉 [`backup-vm-host/WINDOWS.md`](./backup-vm-host/WINDOWS.md)

> ⚠️ O caminho Windows é apresentado como alternativa e deve ser validado com um ciclo completo de backup + restore antes de ser tratado como baseline.

---

## 🔐 Segurança e sanitização

**Nenhuma credencial real deve existir neste repositório.**

Não versione:

```text
.env real
portal.json real
team.json real
senhas
tokens
chaves privadas ou públicas de produção
certificados privados
IPs públicos reais
domínios reais
e-mails reais
dumps SQL
snapshots de produção
logs com dados sensíveis
```

Antes de qualquer push:

```bash
./scripts-repo/pre-push-check.sh
```

Para uma publicação pública, use também uma denylist particular mantida fora do repositório:

```bash
PUBLIC_DENYLIST_FILE=~/denylist.txt ./scripts-repo/pre-push-check.sh
```

Ou apenas o scanner:

```bash
./scripts-repo/scan-secrets.sh
```

Leia também [`SECURITY.md`](./SECURITY.md).

Para publicar esta edição com um histórico Git novo e sem herdar dados do repositório privado, consulte [`docs/PUBLICACAO.md`](./docs/PUBLICACAO.md).

---

## 🧪 Disaster Recovery

Um backup só é considerado confiável depois que um restore é testado.

O roteiro de validação está em:

👉 [`docs/TESTE-DE-DR.md`](./docs/TESTE-DE-DR.md)

O histórico técnico anonimizado das validações está em:

👉 [`docs/HISTORICO-VALIDACOES.md`](./docs/HISTORICO-VALIDACOES.md)

---

## 🧠 Competências demonstradas

Este projeto envolve prática em:

- Linux Server;
- Bash;
- Docker / Docker Compose;
- Nextcloud;
- MariaDB;
- Redis;
- PHP;
- Caddy / reverse proxy;
- HTTPS e DNS;
- systemd e timers;
- SFTP / SSH;
- backup e restore;
- automação de infraestrutura;
- hardening;
- documentação operacional;
- Disaster Recovery;
- troubleshooting em ambiente real.

---

## ⚠️ Aviso

Este repositório é uma **edição pública, anonimizada e voltada a estudo/portfólio**.

O código foi derivado de uma implantação real, mas os dados de identificação e os valores operacionais foram removidos. Antes de usar em qualquer ambiente real, revise todos os scripts, versões, políticas de firewall, retenção, domínios, SMTP, permissões e capacidade da infraestrutura.

---

<div align="center">

### Self-hosted • Backup • Restore • Segurança • Disaster Recovery

**Infraestrutura que pode ser reconstruída é infraestrutura que pode ser mantida.**

</div>
