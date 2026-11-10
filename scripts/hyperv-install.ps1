# Включение роли Hyper-V (Windows 10 Корпоративная). PowerShell 5.1, интернет не нужен.
# Запуск: PowerShell от имени администратора:  .\scripts\hyperv-install.ps1
# Если файлы компонента удалены из системы (precheck: DisabledWithPayloadRemoved или ошибка
# «не удаётся найти исходные файлы»), нужен установочный ISO ТОЙ ЖЕ сборки Windows (17763 для LTSC 2019):
#   .\scripts\hyperv-install.ps1 -IsoPath D:\Win10_LTSC_2019.iso
# или вручную указать источник: -Source wim:E:\sources\install.wim:1
param([string]$Source = '', [string]$IsoPath = '')
$ErrorActionPreference = 'Stop'

# Подходит ли образ из install.wim: Enterprise (EnterpriseS у LTSC) и та же сборка, что у работающей Windows.
# Version у Get-WindowsImage -Index выглядит как 10.0.17763 (без четвёртого числа).
function Test-WimImageMatch([string]$Version, [string]$EditionId, [int]$Build) {
    return ($Version -match "^10\.0\.$Build(\.|$)") -and ($EditionId -match 'Enterprise')
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red
    exit 1
}

$f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
if (-not $f) {
    Write-Host 'Компонента Hyper-V нет в этой Windows (выпуск Home?). Используйте VirtualBox: docs\DEPLOY.md, 3.7.' -ForegroundColor Red
    exit 1
}
if ($f.State -eq 'Enabled') {
    Write-Host 'Hyper-V уже включён. Если ещё не перезагружали после включения - перезагрузите.'
    exit 0
}

# Проверка виртуализации (если Hyper-V уже работает, systeminfo пишет только про гипервизор)
$si = systeminfo | Out-String
if ($si -match 'hypervisor has been detected|низкоуровнев\w+ оболочк|гипервизор') {
    Write-Host 'systeminfo: гипервизор обнаружен, проверка требований пропущена.'
} else {
    Write-Host 'Требования Hyper-V по systeminfo:'
    ($si -split "`r?`n" | Select-Object -Last 8) | ForEach-Object { Write-Host "  $_" }
    if ($si -match 'Virtualization Enabled In Firmware:\s+No' -or $si -match '(Включена виртуализация|Виртуализация включена) (в|во) (микропрограмме|встроенном ПО):\s+Нет') {
        Write-Host 'Виртуализация выключена в BIOS/UEFI. Включите Intel VT-x и перезапустите скрипт.' -ForegroundColor Red
        exit 1
    }
    if ($si -match 'Second Level Address Translation:\s+No' -or $si -match 'Преобразование адресов второго уровня:\s+Нет') {
        Write-Host 'Процессор не поддерживает SLAT - Hyper-V не заработает.' -ForegroundColor Red
        exit 1
    }
}

$mounted = $false; $iso = $null
try {
    if ($IsoPath) {
        $iso = (Resolve-Path -LiteralPath $IsoPath).Path
        $img = Get-DiskImage -ImagePath $iso
        if (-not $img.Attached) { Mount-DiskImage -ImagePath $iso | Out-Null; $mounted = $true }
        $img = Get-DiskImage -ImagePath $iso
        $drv = ($img | Get-Volume | Where-Object DriveLetter | Select-Object -First 1).DriveLetter
        if (-not $drv) { throw 'ISO подключён, но буква диска не назначена' }
        $wim = "${drv}:\sources\install.wim"; $kind = 'wim'
        if (-not (Test-Path -LiteralPath $wim)) { $wim = "${drv}:\sources\install.esd"; $kind = 'esd' }
        if (-not (Test-Path -LiteralPath $wim)) { throw 'В образе нет sources\install.wim / install.esd' }
        $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
        $pick = $null
        foreach ($i in (Get-WindowsImage -ImagePath $wim)) {
            # EditionId и Version есть только у объекта, полученного с -Index
            $d = Get-WindowsImage -ImagePath $wim -Index $i.ImageIndex
            Write-Host ("  образ {0}: {1}, версия {2}, {3}" -f $i.ImageIndex, $d.ImageName, $d.Version, $d.EditionId)
            if (-not $pick -and (Test-WimImageMatch -Version ([string]$d.Version) -EditionId ([string]$d.EditionId) -Build $build)) { $pick = $i.ImageIndex }
        }
        if (-not $pick) { throw "В ISO нет образа Enterprise сборки $build - нужен ISO именно этой версии Windows" }
        $Source = "${kind}:${wim}:$pick"
        Write-Host "Источник: $Source"
    }
    if ($Source) {
        # dism.exe понимает источник wim:<путь>:<индекс>; 3010 - успех, нужна перезагрузка
        & dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart "/Source:$Source" /LimitAccess
        if ($LASTEXITCODE -notin 0, 3010) { throw "dism завершился с кодом $LASTEXITCODE (источник: $Source)" }
    } else {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
    }
}
finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $iso | Out-Null }
}
Write-Host 'Hyper-V включён. ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА Windows. После неё запустите hyperv-create-vm.ps1' -ForegroundColor Yellow
