# Windows, без интернета. Запускать из папки комплекта (PowerShell от администратора).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..
if (-not (Test-Path .env)) { Copy-Item .env.example .env; Write-Host 'Создан .env: ЗАПОЛНИТЕ пароли и запустите скрипт снова.'; notepad .env; exit 1 }

# Проверка контрольных сумм
$bad = 0
Get-Content SHA256SUMS | ForEach-Object {
  $h, $f = $_ -split '\s+', 2
  $f = $f.Trim() -replace '^\*',''
  if (Test-Path $f) { if ((Get-FileHash $f -Algorithm SHA256).Hash.ToLower() -ne $h) { Write-Host "ОШИБКА суммы: $f"; $bad++ } }
}
if ($bad) { throw 'Контрольные суммы не совпали' }

docker load -i images.tar
docker compose up -d --no-build
docker compose ps
Write-Host 'Первичная настройка: docker compose exec zabbix-server python3 /opt/zbx-tools/post_setup.py'
