# Предварительная проверка компьютера перед установкой Zabbix. Ничего не меняет.
# PowerShell 5.1, интернет не нужен. Запуск от имени администратора:
#   Set-ExecutionPolicy -Scope Process Bypass; .\precheck.ps1
# Отчёт сохраняется рядом со скриптом: precheck-<имя компьютера>.txt
$ErrorActionPreference = 'Continue'
$report = New-Object System.Collections.Generic.List[string]
function Out-Line([string]$s, [string]$color = 'Gray') { Write-Host $s -ForegroundColor $color; $report.Add($s) }
function Ok([string]$s)   { Out-Line "  [OK]   $s" 'Green' }
function Warn([string]$s) { Out-Line "  [ВНИМ] $s" 'Yellow' }
function Bad([string]$s)  { Out-Line "  [НЕТ]  $s" 'Red' }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
$build = [int]$os.BuildNumber
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

Out-Line "Проверка: $env:COMPUTERNAME, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Out-Line "Windows: $($os.Caption), сборка $build, выпуск $edition, $($os.OSArchitecture)"
Out-Line "Процессор: $($cpu.Name), ядер $($cpu.NumberOfCores), ОЗУ $ramGB ГБ"
if (-not $isAdmin) { Warn 'Скрипт запущен НЕ от администратора: состояние компонента Hyper-V не проверить' }
Out-Line ''

# --- Виртуализация ---
Out-Line 'Виртуализация (нужна для любого варианта: Hyper-V и Docker Desktop):'
$hvPresent = [bool]$cs.HypervisorPresent
$virtOk = $false; $slatOk = $false
if ($hvPresent) {
    Ok 'Гипервизор уже работает (Hyper-V включён) - проверки BIOS не требуются'
    $virtOk = $true; $slatOk = $true
} else {
    if ($cpu.VirtualizationFirmwareEnabled) { Ok 'Виртуализация включена в BIOS/UEFI'; $virtOk = $true }
    else { Bad 'Виртуализация ВЫКЛЮЧЕНА в BIOS/UEFI: включить Intel Virtualization Technology (VT-x)' }
    if ($cpu.SecondLevelAddressTranslationExtensions) { Ok 'SLAT (EPT) поддерживается'; $slatOk = $true }
    else { Bad 'SLAT не поддерживается процессором: Hyper-V невозможен' }
    if (-not $cpu.VMMonitorModeExtensions) { Bad 'Процессор не поддерживает VT-x' }
    if (-not $os.DataExecutionPrevention_Available) { Bad 'DEP недоступен (включить NX/XD в BIOS)' }
}
Out-Line ''

# --- Hyper-V ---
Out-Line 'Hyper-V (вариант A - виртуальная машина):'
$hvFeature = $null; $hvState = 'неизвестно'
if ($isAdmin) {
    $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    if ($null -eq $hvFeature) { Bad "Компонента Hyper-V нет в этом выпуске Windows ($edition)"; $hvState = 'нет' }
    else {
        $hvState = [string]$hvFeature.State
        if ($hvState -eq 'Enabled') { Ok 'Hyper-V включён' }
        elseif ($hvState -eq 'Disabled') { Ok 'Hyper-V есть, выключен - включит scripts\hyperv-install.ps1' }
        elseif ($hvState -eq 'DisabledWithPayloadRemoved') { Warn 'Файлы Hyper-V удалены из системы: для включения нужен ISO этой версии Windows (параметр -Source)' }
        else { Warn "Состояние Hyper-V: $hvState" }
    }
}
if ($edition -match 'Home|Core') { Bad 'Выпуск Home не содержит Hyper-V' }
$other = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'VirtualBox|VMware Workstation|VMware Player' } | Select-Object -ExpandProperty DisplayName
foreach ($o in $other) { Warn "Установлен другой гипервизор: $o (старые версии конфликтуют с Hyper-V)" }
Out-Line ''

# --- Docker Desktop ---
Out-Line 'Docker Desktop (вариант B):'
if ($build -ge 22631 -or ($build -ge 19045 -and $build -lt 22000)) { Ok "Сборка $build подходит для Docker Desktop" }
else { Bad "Сборка $build не подходит для Docker Desktop (нужна Win10 22H2 19045+ или Win11 23H2 22631+)" }
Out-Line ''

# --- Ресурсы ---
Out-Line 'Ресурсы:'
if ($ramGB -ge 8) { Ok "ОЗУ $ramGB ГБ" } elseif ($ramGB -ge 6) { Warn "ОЗУ $ramGB ГБ: ВМ дать 4 ГБ (-MemoryGB 4)" } else { Bad "ОЗУ $ramGB ГБ: мало для ВМ (нужно от 6-8 ГБ)" }
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $free = [math]::Round($_.FreeSpace / 1GB, 1)
    if ($free -ge 60) { Ok "Диск $($_.DeviceID) свободно $free ГБ" } elseif ($free -ge 20) { Warn "Диск $($_.DeviceID) свободно $free ГБ (ВМ растёт до ~40 ГБ)" } else { Out-Line "  [--]   Диск $($_.DeviceID) свободно $free ГБ" }
}
Out-Line ''

# --- Прочее ---
Out-Line 'Прочее:'
$nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
if ($nics) { foreach ($n in $nics) { Ok "Сеть: $($n.Name) ($($n.InterfaceDescription)), $($n.LinkSpeed)" } } else { Bad 'Нет подключённого физического сетевого адаптера' }
$ff = Test-Path "$env:ProgramFiles\Mozilla Firefox\firefox.exe"
$ch = (Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") -or (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
$ed = (Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")
if ($ff -or $ch -or $ed) { Ok 'Современный браузер установлен' } else { Warn 'Современного браузера нет: поставить Firefox из installers\browsers' }
if (Get-Command ssh.exe -ErrorAction SilentlyContinue) { Ok 'Клиент OpenSSH (ssh/scp) есть' } else { Warn 'Нет ssh/scp: бэкапы из ВМ забирать WinSCP из installers\tools' }
Out-Line ''

# --- Итог ---
Out-Line 'ИТОГ:'
if ($virtOk -and $slatOk -and ($hvState -eq 'Enabled' -or $hvState -eq 'Disabled' -or ($hvState -eq 'неизвестно' -and $edition -match 'Enterprise|Professional|Education'))) {
    Out-Line '  Вариант A (ВМ Hyper-V) возможен.' 'Green'
} elseif ($virtOk -and $slatOk -and $hvState -eq 'DisabledWithPayloadRemoved') {
    Out-Line '  Вариант A возможен при наличии ISO этой Windows (hyperv-install.ps1 -Source).' 'Yellow'
} elseif (-not $virtOk -and $slatOk) {
    Out-Line '  Сначала включите виртуализацию в BIOS/UEFI, затем запустите проверку снова.' 'Yellow'
} else {
    Out-Line '  Вариант A на этом компьютере невозможен. См. docs\DEPLOY.md, раздел «Если Hyper-V недоступен».' 'Red'
}

$file = Join-Path $PSScriptRoot "precheck-$env:COMPUTERNAME.txt"
$report | Out-File -FilePath $file -Encoding UTF8
Write-Host "`nОтчёт: $file"
