# Ежедневный бэкап (путь B, Windows + Docker Desktop): pg_dump + экспорт конфигурации. Папка: .\backups. Хранит 30 копий.
# Запуск: .\scripts\backup.ps1  (расписание: docs\DEPLOY.md, 6.2). Работает и со стеком с картой (docker-compose.map.yml).
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$cf = @('-f', 'docker-compose.yml')
if (Test-Path docker-compose.map.yml) { $cf += @('-f', 'docker-compose.map.yml') }
New-Item -ItemType Directory -Force -Path backups | Out-Null
$d = Get-Date -Format 'yyyyMMdd-HHmm'
# pg_dump пишет файл внутри контейнера (./backups примонтирован) - без перенаправления вывода PowerShell
docker compose @cf exec -T postgres sh -c "pg_dump -U `$POSTGRES_USER -Fc -f /backups/zabbix-$d.dump `$POSTGRES_DB"
if ($LASTEXITCODE) { throw "pg_dump завершился с кодом $LASTEXITCODE" }
$dump = "backups\zabbix-$d.dump"
if (-not (Test-Path $dump) -or (Get-Item $dump).Length -eq 0) { throw "Дамп не создан или пуст: $dump" }
docker compose @cf exec -T zabbix-server python3 /opt/zbx-tools/export_config.py
if ($LASTEXITCODE) { throw "export_config.py завершился с кодом $LASTEXITCODE" }
Get-ChildItem backups -Filter 'zabbix-*.dump' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item
Get-ChildItem backups -Filter 'config-*' -Directory | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -Recurse
Write-Host "backup ok: $dump"
