# Создание и запуск ВМ Zabbix в Hyper-V. PowerShell 5.1, интернет не нужен.
# Пример: .\hyperv-create-vm.ps1 -VhdxPath D:\zabbix-vm-debian12.vhdx -NetAdapterName "Ethernet"
param(
    [Parameter(Mandatory = $true)][string]$VhdxPath,
    [string]$VmName = 'ZabbixVM',
    [int]$MemoryGB = 5,
    [int]$Cpu = 2,
    [string]$NetAdapterName,
    [int]$Generation = 2   # 2 = UEFI (образ содержит EFI-раздел); 1 - если Gen 2 не загрузится
)
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red
    exit 1
}
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    Write-Host 'Модуль Hyper-V не найден. Сначала scripts\hyperv-install.ps1 и перезагрузка.' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $VhdxPath)) { Write-Host "Файл не найден: $VhdxPath" -ForegroundColor Red; exit 1 }
if ($VhdxPath -notmatch '\.vhdx$') { Write-Host 'Нужен файл .vhdx (распакуйте zip).' -ForegroundColor Red; exit 1 }

# Идемпотентность: ВМ уже есть - только запустить
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($vm) {
    Write-Host "ВМ $VmName уже существует (состояние: $($vm.State)). Повторно не создаю."
    if ($vm.State -ne 'Running') { Start-VM -Name $VmName }
} else {
    # Коммутатор: существующий внешний, иначе создать ZabbixExternal
    $sw = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sw) {
        if (-not $NetAdapterName) {
            Write-Host 'Физические сетевые адаптеры:'
            Get-NetAdapter -Physical | Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize | Out-String | Write-Host
            $NetAdapterName = Read-Host 'Введите Name адаптера, к которому подключить ВМ'
        }
        if (-not (Get-NetAdapter -Name $NetAdapterName -Physical -ErrorAction SilentlyContinue)) {
            Write-Host "Адаптер '$NetAdapterName' не найден." -ForegroundColor Red; exit 1
        }
        # внимание: на момент создания внешнего коммутатора сеть хоста кратко пропадает
        $sw = New-VMSwitch -Name 'ZabbixExternal' -NetAdapterName $NetAdapterName -AllowManagementOS $true
    }
    Write-Host "Коммутатор: $($sw.Name)"

    $dir = 'C:\Hyper-V\ZabbixVM'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir (Split-Path $VhdxPath -Leaf)
    if (-not (Test-Path $dst)) {
        Write-Host "Копирование VHDX в $dst ..."
        Copy-Item -Path $VhdxPath -Destination $dst
    }

    $mem = [int64]$MemoryGB * 1GB
    New-VM -Name $VmName -Generation $Generation -MemoryStartupBytes $mem -VHDPath $dst -SwitchName $sw.Name -Path $dir | Out-Null
    Set-VM -Name $VmName -ProcessorCount $Cpu -StaticMemory -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction ShutDown
    if ($Generation -eq 2) {
        Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
    }
    Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface'
    Start-VM -Name $VmName
    Write-Host "ВМ $VmName создана и запущена."
}

Write-Host 'Ожидание IP-адреса (до 5 минут; первый запуск Zabbix ещё дольше - до 10 минут)...'
$ip = $null
for ($i = 0; $i -lt 60 -and -not $ip; $i++) {
    Start-Sleep -Seconds 5
    $addrs = (Get-VMNetworkAdapter -VMName $VmName).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    if ($addrs) { $ip = @($addrs)[0] }
}
if ($ip) {
    Write-Host "IP ВМ: $ip   Веб-интерфейс: http://$ip/ (через ~10 минут)" -ForegroundColor Green
} else {
    Write-Host 'IP пока не получен. Войдите в консоль ВМ (vmconnect localhost ZabbixVM) и выполните: ip a' -ForegroundColor Yellow
}
