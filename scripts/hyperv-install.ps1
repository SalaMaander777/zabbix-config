# Включение роли Hyper-V (Windows 10 Корпоративная). PowerShell 5.1, интернет не нужен.
# Запуск: PowerShell от имени администратора:  .\scripts\hyperv-install.ps1
# Если Windows сообщит, что не найдены исходные файлы (урезанная сборка), укажите
# установочный носитель той же версии: .\scripts\hyperv-install.ps1 -Source E:\sources\sxs
param([string]$Source = '')
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red
    exit 1
}

$f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($f -and $f.State -eq 'Enabled') {
    Write-Host 'Hyper-V уже включён. Если ещё не перезагружали после включения - перезагрузите.'
    exit 0
}

# Проверка виртуализации (если Hyper-V уже работает, systeminfo пишет только про гипервизор)
$si = systeminfo | Out-String
if ($si -match 'hypervisor has been detected|гипервизор') {
    Write-Host 'systeminfo: гипервизор обнаружен, проверка требований пропущена.'
} else {
    Write-Host 'Требования Hyper-V по systeminfo:'
    ($si -split "`r?`n" | Select-Object -Last 8) | ForEach-Object { Write-Host "  $_" }
    if ($si -match 'Virtualization Enabled In Firmware:\s+No' -or $si -match 'Включена виртуализация в микропрограмме:\s+Нет') {
        Write-Host 'Виртуализация выключена в BIOS/UEFI. Включите Intel VT-x и перезапустите скрипт.' -ForegroundColor Red
        exit 1
    }
    if ($si -match 'Second Level Address Translation:\s+No' -or $si -match 'Преобразование адресов второго уровня:\s+Нет') {
        Write-Host 'Процессор не поддерживает SLAT - Hyper-V не заработает.' -ForegroundColor Red
        exit 1
    }
}

if ($Source) {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -Source $Source -LimitAccess | Out-Null
} else {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart | Out-Null
}
Write-Host 'Hyper-V включён. ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА Windows. После неё запустите scripts\hyperv-create-vm.ps1' -ForegroundColor Yellow
