# Установка VirtualBox на Windows без интернета (запасной вариант A2, docs\DEPLOY.md, раздел 3.7).
# PowerShell 5.1, от имени администратора. Ставит по очереди: Visual C++ Redistributable x64, VirtualBox.
# Пример: .\virtualbox-install.ps1 -InstallerDir D:\zabbix-offline\installers\virtualbox
param(
    [string]$InstallerDir = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red
    exit 1
}
if (-not [Environment]::Is64BitOperatingSystem) { Write-Host 'Нужна 64-разрядная Windows.' -ForegroundColor Red; exit 1 }

$vbm = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (Test-Path $vbm) {
    Write-Host "VirtualBox уже установлен: $(& $vbm --version)" -ForegroundColor Green
    exit 0
}
if (-not (Test-Path $InstallerDir)) { Write-Host "Папка не найдена: $InstallerDir" -ForegroundColor Red; exit 1 }

$vc = Get-ChildItem -Path $InstallerDir -Filter 'vc_redist.x64.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
$vb = Get-ChildItem -Path $InstallerDir -Filter 'VirtualBox-*-Win.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vc) { Write-Host "Не найден vc_redist.x64.exe в $InstallerDir" -ForegroundColor Red; exit 1 }
if (-not $vb) { Write-Host "Не найден VirtualBox-*-Win.exe в $InstallerDir" -ForegroundColor Red; exit 1 }

# Проверка SHA256 по SHA256SUMS рядом с установщиком (если файл есть)
$sums = Join-Path $vb.DirectoryName 'SHA256SUMS'
if (Test-Path $sums) {
    $line = Get-Content $sums | Where-Object { $_ -match [regex]::Escape($vb.Name) } | Select-Object -First 1
    if ($line) {
        $want = ($line -split '\s+')[0].ToLower()
        $have = (Get-FileHash -Algorithm SHA256 -Path $vb.FullName).Hash.ToLower()
        if ($want -ne $have) { Write-Host "Контрольная сумма $($vb.Name) не совпала: файл повреждён." -ForegroundColor Red; exit 1 }
        Write-Host 'SHA256 установщика VirtualBox совпал.' -ForegroundColor Green
    }
}

Write-Host 'Установка Microsoft Visual C++ Redistributable x64 ...'
$p = Start-Process -FilePath $vc.FullName -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
# 0 - готово, 3010 - нужна перезагрузка, 1638 - уже стоит такая или более новая версия
if ($p.ExitCode -notin 0, 3010, 1638) { Write-Host "vc_redist завершился с кодом $($p.ExitCode)" -ForegroundColor Red; exit 1 }
Write-Host "vc_redist: код $($p.ExitCode)"

Write-Host 'Установка VirtualBox (1-3 минуты; сеть компьютера может кратковременно пропасть - ставится драйвер моста) ...'
$p = Start-Process -FilePath $vb.FullName -ArgumentList '--silent', '--ignore-reboot' -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { Write-Host "Установщик VirtualBox завершился с кодом $($p.ExitCode)" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $vbm)) { Write-Host 'VBoxManage.exe не найден после установки.' -ForegroundColor Red; exit 1 }
Write-Host "VirtualBox установлен: $(& $vbm --version)" -ForegroundColor Green
if ($p.ExitCode -eq 3010) { Write-Host 'Рекомендуется перезагрузить Windows.' -ForegroundColor Yellow }
Write-Host 'Дальше: .\virtualbox-create-vm.ps1 -DiskPath <путь к zabbix-vm-debian12.vdi или -vdi.zip>'
