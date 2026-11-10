# Восстановление: .\scripts\restore.ps1 backups\zabbix-YYYYMMDD-HHMM.dump
param([Parameter(Mandatory)][string]$Dump)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..
$name = Split-Path $Dump -Leaf
docker compose stop zabbix-server zabbix-web
docker compose exec -T postgres sh -c "pg_restore -U `$POSTGRES_USER -d `$POSTGRES_DB --clean --if-exists /backups/$name"
docker compose start zabbix-server zabbix-web
