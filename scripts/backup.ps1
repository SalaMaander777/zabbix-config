# Ежедневный бэкап: pg_dump + экспорт конфигурации. Папка: .\backups. Хранит 30 копий.
# Регистрация: см. docs/RUNBOOK.md (Task Scheduler).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..
$d = Get-Date -Format 'yyyyMMdd-HHmm'
# pg_dump пишет файл внутри контейнера (./backups примонтирован) - без перенаправления вывода PowerShell
docker compose exec -T postgres sh -c "pg_dump -U `$POSTGRES_USER -Fc -f /backups/zabbix-$d.dump `$POSTGRES_DB"
docker compose exec -T zabbix-server python3 /opt/zbx-tools/export_config.py
Get-ChildItem backups\zabbix-*.dump | Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item
Get-ChildItem backups\config-* -Directory | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -Recurse
