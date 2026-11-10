# Создание и запуск ВМ Zabbix в VirtualBox из готового диска (VDI). PowerShell 5.1, интернет не нужен.
# Пример: .\virtualbox-create-vm.ps1 -DiskPath D:\zabbix-vm-debian12.vdi -NetAdapterName "Ethernet"
# Параметры -NoStart и -NoAutostart нужны для проверки в CI (ВМ не запускается, задачи планировщика не создаются).
param(
    [Parameter(Mandatory = $true)][string]$DiskPath,   # .vdi, .vmdk или zip с vdi
    [string]$VmName = 'ZabbixVM',
    [int]$MemoryGB = 5,
    [int]$Cpu = 2,
    [string]$NetAdapterName,                            # имя адаптера Windows (Ethernet) или имя из VBoxManage list bridgedifs
    [string]$BaseFolder = 'C:\VirtualBox',
    [ValidateSet('separate', 'headless', 'gui')][string]$StartType = 'separate',  # separate - окно консоли, которое можно закрыть, ВМ продолжит работать
    [switch]$NoStart,
    [switch]$NoAutostart
)
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red
    exit 1
}
$vbm = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $vbm)) { Write-Host 'VirtualBox не установлен. Сначала scripts\virtualbox-install.ps1.' -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $DiskPath -PathType Leaf)) { Write-Host "Файл не найден: $DiskPath" -ForegroundColor Red; exit 1 }

function Vbm {
    & $vbm @args
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') завершился с кодом $LASTEXITCODE" }
}

# Идемпотентность: ВМ уже есть - только запустить
$ErrorActionPreference = 'Continue'
$null = & $vbm showvminfo $VmName --machinereadable 2>$null
$exists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if ($exists) {
    Write-Host "ВМ $VmName уже существует. Повторно не создаю."
    $state = (& $vbm showvminfo $VmName --machinereadable | Select-String '^VMState="(.*)"').Matches[0].Groups[1].Value
    if (-not $NoStart -and $state -ne 'running') { Vbm startvm $VmName --type $StartType }
    exit 0
}

# --- Мост: выбор физического адаптера ---
function ConvertFrom-BridgedIfs([string[]]$Lines) {
    $list = @(); $cur = $null
    foreach ($l in $Lines) {
        if ($l -match '^Name:\s+(.+?)\s*$') { $cur = [pscustomobject]@{ Name = $Matches[1]; Status = ''; Wireless = '' }; $list += $cur }
        elseif ($cur -and $l -match '^Status:\s+(.+?)\s*$') { $cur.Status = $Matches[1] }
        elseif ($cur -and $l -match '^Wireless:\s+(.+?)\s*$') { $cur.Wireless = $Matches[1] }
    }
    return $list
}
function Get-BridgedIfs { return ConvertFrom-BridgedIfs @(& $vbm list bridgedifs) }
function Show-Ifs($ifs) {
    for ($i = 0; $i -lt $ifs.Count; $i++) { Write-Host ("  {0}) {1}  [{2}{3}]" -f ($i + 1), $ifs[$i].Name, $ifs[$i].Status, $(if ($ifs[$i].Wireless -eq 'Yes') { ', Wi-Fi' } else { '' })) }
}
$ifs = @(Get-BridgedIfs)
if ($ifs.Count -eq 0) { Write-Host 'VBoxManage list bridgedifs пуст: драйвер сетевого моста VirtualBox не установлен (переустановите VirtualBox).' -ForegroundColor Red; exit 1 }
$bridge = $null
if ($NetAdapterName) {
    $bridge = ($ifs | Where-Object { $_.Name -ieq $NetAdapterName } | Select-Object -First 1).Name
    if (-not $bridge) {
        $na = Get-NetAdapter -Name $NetAdapterName -ErrorAction SilentlyContinue
        if ($na) { $bridge = ($ifs | Where-Object { $_.Name -ieq $na.InterfaceDescription -or $_.Name.StartsWith($na.InterfaceDescription) } | Select-Object -First 1).Name }
    }
    if (-not $bridge) {
        Write-Host "Адаптер '$NetAdapterName' не найден среди адаптеров VirtualBox. Доступные:" -ForegroundColor Red
        Show-Ifs $ifs
        Write-Host 'Повторите с -NetAdapterName "<имя из списка>".'
        exit 1
    }
} else {
    Write-Host 'Физические сетевые адаптеры для моста (VBoxManage list bridgedifs):'
    Show-Ifs $ifs
    $n = [int](Read-Host 'Введите номер адаптера, к которому подключить ВМ')
    if ($n -lt 1 -or $n -gt $ifs.Count) { Write-Host 'Неверный номер.' -ForegroundColor Red; exit 1 }
    $bridge = $ifs[$n - 1].Name
}
$sel = $ifs | Where-Object { $_.Name -eq $bridge } | Select-Object -First 1
if ($sel.Wireless -eq 'Yes') { Write-Host 'ВНИМАНИЕ: мост через Wi-Fi работает плохо (ВМ может не получить адрес). Используйте проводной адаптер.' -ForegroundColor Yellow }
Write-Host "Мост: $bridge"

# --- Создание ВМ ---
$dir = Join-Path $BaseFolder $VmName
$dst = $null
try {
Vbm createvm --name $VmName --ostype Debian_64 --basefolder $BaseFolder --register
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$src = (Resolve-Path $DiskPath).Path
if ($src -match '\.zip$') {
    Write-Host "Распаковка $src в $dir ..."
    Expand-Archive -LiteralPath $src -DestinationPath $dir -Force
    $dst = (Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Extension -in '.vdi', '.vmdk' } | Select-Object -First 1).FullName
    if (-not $dst) { throw 'В zip не найден .vdi/.vmdk' }
} elseif ($src -match '\.(vdi|vmdk)$') {
    $dst = Join-Path $dir (Split-Path $src -Leaf)
    if ($src -ne $dst) { Write-Host "Копирование диска в $dst ..."; Copy-Item -LiteralPath $src -Destination $dst }
} else {
    throw 'Нужен файл .vdi, .vmdk или zip с ним. Формат VHDX (для Hyper-V) в VirtualBox не используется.'
}

# новый UUID диска: копия не должна совпадать с уже зарегистрированным диском (иначе VirtualBox откажется её подключить)
Vbm internalcommands sethduuid $dst

$memMB = $MemoryGB * 1024
Vbm modifyvm $VmName --memory $memMB --cpus $Cpu --firmware bios --ioapic on --rtcuseutc on --graphicscontroller vmsvga --vram 16 `
    --nic1 bridged --bridgeadapter1 $bridge --nictype1 82540EM --cableconnected1 on --boot1 disk --boot2 none --boot3 none --boot4 none
Vbm storagectl $VmName --name SATA --add sata --controller IntelAhci --portcount 1 --bootable on
Vbm storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $dst
}
catch {
    # недосозданную ВМ не оставляем: повторный запуск счёл бы её готовой и просто запустил
    $ErrorActionPreference = 'Continue'
    & $vbm unregistervm $VmName --delete 2>$null | Out-Null
    if ($dst -and $dst -ne $src) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
    throw
}
Write-Host "ВМ $VmName создана: $memMB МБ ОЗУ, $Cpu ЦП, BIOS, SATA AHCI, сеть Intel PRO/1000 MT Desktop (мост: $bridge)." -ForegroundColor Green

$mac = (& $vbm showvminfo $VmName --machinereadable | Select-String '^macaddress1="(.*)"').Matches[0].Groups[1].Value
$macDash = ($mac -replace '(..)(?!$)', '$1-')
Write-Host "MAC-адрес ВМ: $macDash"

# --- Автозапуск без входа пользователя (планировщик заданий) ---
if (-not $NoAutostart) {
    $who = "$env:USERDOMAIN\$env:USERNAME"
    Write-Host "Автозапуск ВМ при загрузке Windows. VirtualBox хранит список ВМ в профиле пользователя, поэтому задача идёт от $who."
    $cred = Get-Credential -UserName $who -Message "Пароль пользователя $who для задачи планировщика (не пустой)"
    if (-not $cred -or -not $cred.GetNetworkCredential().Password) { Write-Host 'Пароль не введён (пустой не подходит): автозапуск не настроен.' -ForegroundColor Yellow }
    else {
        $pw = $cred.GetNetworkCredential().Password
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        # 1) запуск при старте Windows, через 30 секунд
        $act = New-ScheduledTaskAction -Execute $vbm -Argument "startvm `"$VmName`" --type headless"
        $trg = New-ScheduledTaskTrigger -AtStartup
        $trg.Delay = 'PT30S'
        Register-ScheduledTask -TaskName "Start-$VmName" -Action $act -Trigger $trg -Settings $set -User $cred.UserName -Password $pw -RunLevel Highest -Force | Out-Null
        # 2) попытка корректного выключения при завершении работы Windows (событие 1074 - выключение начато)
        $stopPs = Join-Path $dir 'stop-vm.ps1'
        @"
& '$vbm' controlvm $VmName acpipowerbutton
for (`$i = 0; `$i -lt 60; `$i++) { Start-Sleep -Seconds 2; if (-not ((& '$vbm' list runningvms) -match '$VmName')) { break } }
"@ | Set-Content -Path $stopPs -Encoding UTF8
        $act2 = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stopPs`""
        $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $trg2 = New-CimInstance -CimClass $cls -ClientOnly
        $trg2.Enabled = $true
        $trg2.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''User32''] and EventID=1074]]</Select></Query></QueryList>'
        Register-ScheduledTask -TaskName "Stop-$VmName" -Action $act2 -Trigger $trg2 -Settings $set -User $cred.UserName -Password $pw -RunLevel Highest -Force | Out-Null
        Write-Host "Задачи планировщика созданы: Start-$VmName (при запуске системы), Stop-$VmName (при выключении, как получится)." -ForegroundColor Green
        Write-Host 'Выключение Windows НЕ ждёт эту задачу: гарантии корректной остановки ВМ нет (база PostgreSQL восстановится по журналу).' -ForegroundColor Yellow
        Write-Host "Корректно выключить вручную перед остановкой Windows:  & '$vbm' controlvm $VmName acpipowerbutton"
    }
}

if ($NoStart) { Write-Host 'Запуск пропущен (-NoStart).'; exit 0 }
Vbm startvm $VmName --type $StartType
Write-Host "ВМ запущена (режим: $StartType)." -ForegroundColor Green
Write-Host 'IP-адрес ВМ: гостевых дополнений нет, поэтому VBoxManage его не покажет. Узнайте так:'
Write-Host '  1) в консоли ВМ (окно VirtualBox) войдите zbxadmin и выполните: ip -br a'
Write-Host "  2) или найдите в списке аренд DHCP роутера по MAC $macDash"
Write-Host 'Первый запуск Zabbix занимает до 10 минут (docs\DEPLOY.md, 3.4-3.5).'
