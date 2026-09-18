# Host Windows — adaptação do fluxo de backup

> **STATUS: EXPERIMENTAL / NÃO VALIDADO EM PRODUÇÃO.** O fluxo de produção comprovado usa host Debian. Não trate o modo Windows como único mecanismo de recuperação até executar e registrar um ciclo completo de **backup + checksum + restore** usando exatamente o computador/VirtualBox/HD que ficarão responsáveis pela rotina.

A VPS continua sendo Linux. O Windows substitui apenas o notebook/estação que hospeda o VirtualBox e a VM Debian de backup.

## Quando usar

Use este caminho se a empresa decidir hospedar a VM de backup em uma estação Windows. Se houver liberdade de escolha e o objetivo for reproduzir o baseline já comprovado, prefira o host Linux/Debian até o fluxo Windows também ser formalmente validado.

## Requisitos

- Windows 10/11 atualizado.
- VirtualBox instalado.
- OpenSSH Client do Windows ou WinSCP para transferências administrativas.
- VM Debian já configurada com `backup-vm-host/install-vm-linux.sh`.
- HD externo configurado como USB passthrough para a VM.

## Agendamento

No Debian host usamos systemd timers. No Windows use **Agendador de Tarefas**:

1. Crie uma tarefa diária no horário desejado.
2. Programa: `powershell.exe`.
3. Argumentos: `-ExecutionPolicy Bypass -File "CAMINHO_DO_REPO\\backup-vm-host\\windows\\start-portal-backup.ps1" -VmName "NOME_DA_VM"`.
4. Marque para executar com privilégios adequados ao usuário que possui a VM no VirtualBox.
5. O script apenas inicia a VM. Dentro dela, `portal-backup-boot.service` aguarda rede/HD, puxa, valida, grava o status e desliga.

## Diferenças em relação ao host Debian

`portal-backup-host-run.sh` e seus timers são específicos de Linux. No Windows não tente instalar unidades systemd no host. O controle de bateria, desmontagem Linux e leitura automática do `last-run.json` precisam ser substituídos por procedimentos do Windows ou validados manualmente.

## Validação obrigatória antes de confiar neste modo

1. iniciar a VM pelo PowerShell/Agendador;
2. confirmar que o HD foi capturado pela VM;
3. confirmar `.tar.gz`, `.sha256` e `.ok` no HD;
4. conferir `logs/last-run.json` e verificar que o timestamp corresponde à execução atual;
5. desligar/ligar a estação e repetir o ciclo automático;
6. realizar um restore controlado de um snapshot de teste;
7. registrar o teste em `docs/HISTORICO-VALIDACOES.md` e somente então classificar o modo Windows como validado.

Até esse teste existir, mantenha o caminho Debian como referência oficial comprovada.
