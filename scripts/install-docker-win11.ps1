# Установка WSL2 и Docker Desktop без интернета. Windows 11 (или Windows 10 22H2, сборка 19045+).
# PowerShell от администратора, из папки комплекта: .\scripts\install-docker-win11.ps1
# НЕ подходит для Windows 10 LTSC 2019 (сборка 17763): см. docs/WINDOWS-TARGET.md
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Запустите PowerShell от имени администратора.' -ForegroundColor Red
    exit 1
}
Set-Location (Join-Path $PSScriptRoot '..')
$root = (Get-Location).Path
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 19045) { throw "Сборка Windows ${build}: Docker Desktop требует 19045+ (см. docs/WINDOWS-TARGET.md)" }

if (-not (Test-Path -LiteralPath (Join-Path $root 'installers'))) { throw 'Не найдена папка installers рядом с папкой scripts. Похоже, скачан исходный код репозитория (Code -> Download ZIP), а нужен готовый комплект: GitHub -> Actions -> offline-bundle -> последний зелёный запуск -> Artifacts -> zabbix-offline. См. docs/DEPLOY.md, раздел 2.1.' }
$wsl = Get-ChildItem -Path (Join-Path $root 'installers') -Filter 'wsl*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
$dd = Join-Path $root 'installers\DockerDesktopInstaller.exe'
if (-not $wsl) { throw 'Не найден installers\wsl*.msi' }
if (-not (Test-Path -LiteralPath $dd)) { throw 'Не найден installers\DockerDesktopInstaller.exe' }

Write-Host '1/3 Компоненты Windows (интернет не нужен)'
foreach ($feat in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
    dism.exe /online /enable-feature "/featurename:$feat" /all /norestart | Out-Null
    # 3010 - успех, нужна перезагрузка
    if ($LASTEXITCODE -notin 0, 3010) { throw "dism ($feat) завершился с кодом $LASTEXITCODE" }
}

Write-Host '2/3 WSL'
$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i', "`"$($wsl.FullName)`"", '/qn', '/norestart'
if ($p.ExitCode -notin 0, 3010, 1638) { throw "Установка WSL (msiexec) завершилась с кодом $($p.ExitCode)" }

Write-Host '3/3 Docker Desktop (несколько минут)'
# ключи: https://docs.docker.com/desktop/setup/install/windows-install/ ; лицензию пользователь принимает при первом запуске
$p = Start-Process -FilePath $dd -Wait -PassThru -ArgumentList 'install', '--quiet', '--backend=wsl-2', '--always-run-service'
if ($p.ExitCode -notin 0, 3010) { throw "Установщик Docker Desktop завершился с кодом $($p.ExitCode)" }

Write-Host 'Готово. ПЕРЕЗАГРУЗИТЕ компьютер, запустите Docker Desktop, примите лицензию,'
Write-Host 'в Settings > General включите "Start Docker Desktop when you sign in", затем: .\scripts\load-and-start.ps1'
