# VM e host do backup externo

Esta pasta cobre a segunda cópia do Portal Interno: a VPS gera o snapshot e uma VM Debian puxa os arquivos por SFTP somente leitura para um HD externo.

## Fluxo validado em Linux/Debian

```text
VPS -> SFTP read-only -> VM Debian -> HD externo por USB passthrough
```

### 1. Preparar a VM Debian

Copie este repositório ou, no mínimo, `backup-vm-host/` e `backup/systemd/` para a VM. Com o HD já visível por USB passthrough:

```bash
cd portal-interno-selfhosted
sudo ./backup-vm-host/install-vm-linux.sh
```

O instalador:

- cria o usuário de serviço `backupreader`;
- gera uma chave Ed25519 **dentro da VM**;
- pede host/porta da VPS e confirma o fingerprint;
- pede o UUID da partição do HD visto dentro da VM;
- configura o mount com permissões adequadas, inclusive exFAT;
- instala `portal-backup-pull.service` e `portal-backup-boot.service`.

A chave privada nunca sai da VM. Para a VPS, transfira apenas a chave pública gerada.

### 2. Autorizar a VM na VPS

Na VPS:

```bash
sudo /opt/portal-interno/scripts/configurar-chave-backup.sh /caminho/CHAVE_PUBLICA_DA_VM.pub
```

### 3. Testar dentro da VM

```bash
sudo testar-portal-backup
sudo testar-portal-backup --pull
```

Confirme `.tar.gz`, `.sha256`, marcador `.ok` e `logs/last-run.json` no HD.

### 4. Automatizar pelo notebook Linux

No notebook Debian que hospeda o VirtualBox:

```bash
sudo ./backup-vm-host/install-host-linux.sh
sudo /usr/local/sbin/portal-backup-host-run.sh manual
```

O host desmonta o HD antes do passthrough, inicia a VM, espera a coleta, lê o status da execução atual e pode suspender novamente no ciclo noturno.

## Host Windows

Não use os scripts systemd do host Linux no Windows. Veja `WINDOWS.md` e `windows/start-portal-backup.ps1`.
