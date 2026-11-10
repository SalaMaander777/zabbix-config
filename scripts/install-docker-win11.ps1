# Установка WSL2 и Docker Desktop без интернета. Windows 11 (или Windows 10 22H2, сборка 19045+).
# PowerShell от администратора, из папки комплекта: .\scripts\install-docker-win11.ps1
# НЕ подходит для Windows 10 LTSC 2019 (сборка 17763): см. docs/WINDOWS-TARGET.md
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 19045) { throw "Сборка Windows $build: Docker Desktop требует 19045+ (см. docs/WINDOWS-TARGET.md)" }

Write-Host '1/3 Компоненты Windows (интернет не нужен)'
dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null

Write-Host '2/3 WSL'
$wsl = Get-ChildItem installers\wsl*.msi | Select-Object -First 1
Start-Process msiexec -Wait -ArgumentList '/i', "`"$($wsl.FullName)`"", '/qn', '/norestart'

Write-Host '3/3 Docker Desktop (несколько минут)'
Start-Process 'installers\DockerDesktopInstaller.exe' -Wait -ArgumentList 'install', '--quiet', '--backend=wsl-2', '--always-run-service'

Write-Host 'Готово. ПЕРЕЗАГРУЗИТЕ компьютер, запустите Docker Desktop, примите лицензию,'
Write-Host 'в Settings > General включите "Start Docker Desktop when you sign in", затем: .\scripts\load-and-start.ps1'
