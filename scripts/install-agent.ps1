# Установка агента Zabbix на ПК Windows без интернета (в т.ч. на сам главный компьютер с ВМ).
# PowerShell 5.1, от имени администратора. Пример:
#   .\install-agent.ps1 -Server 192.168.1.50
#   .\install-agent.ps1 -Server 192.168.1.50 -HostName arm-01 -InstallerDir D:\zabbix-offline\installers
# -Server  - IP сервера Zabbix: на пути A/A2 это IP ВИРТУАЛЬНОЙ МАШИНЫ, а не Windows.
# Агент выбирается сам: Windows 10/11 x64 - агент 2, Windows 7/8.1 - классический агент (x64 или x86).
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$HostName = $env:COMPUTERNAME,
    [string]$InstallerDir = '',
    [ValidateSet('auto', 'agent2', 'agent')][string]$Kind = 'auto'
)
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red
    exit 1
}
if ($Server -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Неверный IP сервера: $Server" }

if (-not $InstallerDir) {
    # скрипт лежит в <комплект>\scripts, установщики - в <комплект>\installers
    $InstallerDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'installers'
    if (-not (Test-Path -LiteralPath $InstallerDir)) { $InstallerDir = $PSScriptRoot }
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$is64 = [Environment]::Is64BitOperatingSystem
if ($Kind -eq 'auto') {
    if ($build -ge 10240 -and $is64) { $Kind = 'agent2' } else { $Kind = 'agent' }
}
if ($Kind -eq 'agent2') {
    if (-not $is64) { throw 'Агент 2 в комплекте только для x64. Используйте -Kind agent.' }
    $pattern = 'zabbix_agent2-*-windows-amd64-openssl.msi'; $svc = 'Zabbix Agent 2'
} else {
    if ($is64) { $pattern = 'zabbix_agent-*-windows-amd64-openssl.msi' } else { $pattern = 'zabbix_agent-*-windows-i386-openssl.msi' }
    $svc = 'Zabbix Agent'
}
$msi = Get-ChildItem -LiteralPath $InstallerDir -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $msi) { throw "Не найден установщик $pattern в $InstallerDir (укажите -InstallerDir)" }

Write-Host "Windows: $($os.Caption), сборка $build, x64=$is64"
Write-Host "Ставится: $($msi.Name) (служба '$svc'), сервер $Server, имя узла $HostName"

$log = Join-Path $env:TEMP 'zabbix-agent-install.log'
$msiArgs = @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart', '/l*v', "`"$log`"",
          "SERVER=$Server", "SERVERACTIVE=$Server", "HOSTNAME=$HostName")
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010 -and $p.ExitCode -ne 1638) {
    throw "msiexec завершился с кодом $($p.ExitCode), журнал: $log"
}
if ($p.ExitCode -eq 1638) { Write-Host 'Агент уже установлен (код 1638). Для смены сервера удалите его в «Программы и компоненты» и запустите снова.' -ForegroundColor Yellow }

# Брандмауэр: входящий TCP 10050 (пассивные проверки с сервера)
$rule = 'Zabbix agent 10050'
if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort 10050 -Action Allow | Out-Null
    Write-Host "Правило брандмауэра '$rule' создано"
}

$s = Get-Service -Name $svc -ErrorAction SilentlyContinue
if (-not $s) { throw "Служба '$svc' не найдена после установки, журнал: $log" }
if ($s.Status -ne 'Running') { Start-Service -Name $svc; $s.Refresh() }
Set-Service -Name $svc -StartupType Automatic
Write-Host "Служба '$svc': $($s.Status)" -ForegroundColor Green
Write-Host ''
Write-Host 'Дальше в Zabbix: Сбор данных -> Узлы сети -> Создать узел:'
Write-Host "  Имя узла: $HostName (точно так же, как здесь)"
Write-Host "  Интерфейс: Агент, IP этого ПК, порт 10050"
Write-Host "  Шаблон: Windows by Zabbix agent"
