# Включение роли Hyper-V (Windows 10 Корпоративная). PowerShell 5.1, интернет не нужен.
# Запуск: PowerShell от имени администратора:  .\scripts\hyperv-install.ps1
# Если файлы компонента удалены из системы (precheck: DisabledWithPayloadRemoved или ошибка
# «не удаётся найти исходные файлы»), нужен установочный ISO ТОЙ ЖЕ сборки Windows (17763 для LTSC 2019):
#   .\scripts\hyperv-install.ps1 -IsoPath D:\Win10_LTSC_2019.iso
# или вручную указать источник: -Source wim:E:\sources\install.wim:1
param([string]$Source = '', [string]$IsoPath = '')
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

if ($IsoPath) {
    $iso = (Resolve-Path $IsoPath).Path
    $img = Get-DiskImage -ImagePath $iso
    if (-not $img.Attached) { $img = Mount-DiskImage -ImagePath $iso -PassThru }
    $drv = ($img | Get-Volume).DriveLetter
    $wim = "${drv}:\sources\install.wim"; $kind = 'wim'
    if (-not (Test-Path $wim)) { $wim = "${drv}:\sources\install.esd"; $kind = 'esd' }
    if (-not (Test-Path $wim)) { throw "В образе нет sources\install.wim / install.esd" }
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    $images = Get-WindowsImage -ImagePath $wim
    $pick = $null
    foreach ($i in $images) {
        $d = Get-WindowsImage -ImagePath $wim -Index $i.ImageIndex
        Write-Host ("  образ {0}: {1}, версия {2}" -f $i.ImageIndex, $d.ImageName, $d.Version)
        if ($d.Version -like "10.0.$build.*" -and $d.EditionId -match 'Enterprise' -and -not $pick) { $pick = $i.ImageIndex }
    }
    if (-not $pick) { throw "В ISO нет образа Enterprise сборки $build - нужен ISO именно этой версии Windows" }
    $Source = "${kind}:${wim}:$pick"
    Write-Host "Источник: $Source"
}
if ($Source) {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -Source $Source -LimitAccess | Out-Null
} else {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart | Out-Null
}
Write-Host 'Hyper-V включён. ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА Windows. После неё запустите scripts\hyperv-create-vm.ps1' -ForegroundColor Yellow
