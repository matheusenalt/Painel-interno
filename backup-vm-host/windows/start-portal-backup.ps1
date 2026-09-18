param(
  [string]$VmName = "NOME_DA_VM_DE_BACKUP",
  [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path $VBoxManage)) { throw "VBoxManage não encontrado em: $VBoxManage" }
$running = & $VBoxManage list runningvms
if ($running -match ('"' + [regex]::Escape($VmName) + '"')) {
  Write-Host "A VM já está em execução."
  exit 0
}
& $VBoxManage startvm $VmName --type headless
if ($LASTEXITCODE -ne 0) { throw "Falha ao iniciar a VM de backup." }
Write-Host "VM iniciada. O serviço portal-backup-boot.service dentro do Debian fará a coleta e desligará a VM ao terminar."
