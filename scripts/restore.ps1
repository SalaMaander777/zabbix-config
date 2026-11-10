# Восстановление БД из дампа (путь B): .\scripts\restore.ps1 backups\zabbix-YYYYMMDD-HHMM.dump
param([Parameter(Mandatory)][string]$Dump)
$ErrorActionPreference = 'Stop'
$dumpFull = (Resolve-Path -LiteralPath $Dump).Path   # путь относительно папки, из которой запущен скрипт
Set-Location (Join-Path $PSScriptRoot '..')
$cf = @('-f', 'docker-compose.yml')
if (Test-Path docker-compose.map.yml) { $cf += @('-f', 'docker-compose.map.yml') }
New-Item -ItemType Directory -Force -Path backups | Out-Null
$name = Split-Path $dumpFull -Leaf
if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "Недопустимое имя файла дампа: $name (только латиница, цифры, . _ -)" }
$inBackups = Join-Path (Resolve-Path backups).Path $name
if ($dumpFull -ne $inBackups) {
    # контейнер видит только папку backups: положить дамп туда
    Copy-Item -LiteralPath $dumpFull -Destination $inBackups -Force
}

docker compose @cf stop zabbix-server zabbix-web
if ($LASTEXITCODE) { throw "docker compose stop завершился с кодом $LASTEXITCODE" }
$rc = 0
try {
    docker compose @cf exec -T postgres sh -c "pg_restore -U `$POSTGRES_USER -d `$POSTGRES_DB --clean --if-exists /backups/$name"
    $rc = $LASTEXITCODE
}
finally {
    # сервисы запускаем в любом случае, чтобы не оставить систему остановленной
    docker compose @cf start zabbix-server zabbix-web
}
if ($rc) { throw "pg_restore завершился с кодом ${rc}: восстановление могло пройти не полностью, смотрите вывод выше" }
Write-Host 'Восстановление завершено.' -ForegroundColor Green
