# Windows, без интернета. Запускать из папки комплекта (PowerShell от администратора): .\scripts\load-and-start.ps1
# Скрипт лежит в подпапке scripts\ комплекта zabbix-offline; корень комплекта - на уровень выше (там images.tar, SHA256SUMS).
$ErrorActionPreference = 'Stop'

# Разбор строк SHA256SUMS в формате sha256sum/shasum: "<hash>  ./путь" или "<hash> *./путь" (двоичный режим).
# Возвращает объекты Hash (нижний регистр) и Path (относительный, с обратными слэшами, без ведущего ./).
function ConvertFrom-Sha256Sums([string[]]$Lines) {
    foreach ($l in $Lines) {
        $line = $l.Trim([char]0xFEFF).TrimEnd("`r", "`n")
        if ($line -match '^\\?([0-9A-Fa-f]{64}) [ *](.+?)\s*$') {
            $p = $Matches[2] -replace '/', '\'
            $p = $p -replace '^(\.\\)+', ''
            [pscustomobject]@{ Hash = $Matches[1].ToLower(); Path = $p }
        }
    }
}

# Проверка файлов под корнем $Root. Результат: объекты Path и Status (Ok, Mismatch, Missing).
function Test-Sha256Sums([string]$Root, [string[]]$Lines) {
    foreach ($e in @(ConvertFrom-Sha256Sums $Lines)) {
        $full = Join-Path $Root $e.Path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $st = 'Missing' }
        elseif ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower() -eq $e.Hash) { $st = 'Ok' }
        else { $st = 'Mismatch' }
        [pscustomobject]@{ Path = $e.Path; Status = $st }
    }
}

Set-Location (Join-Path $PSScriptRoot '..')
if (-not (Test-Path .env)) {
    Copy-Item .env.example .env
    Write-Host 'Создан .env: ЗАПОЛНИТЕ пароли (POSTGRES_PASSWORD) и запустите скрипт снова.'
    notepad .env
    exit 1
}
if (Select-String -Path .env -Pattern '^\s*POSTGRES_PASSWORD=CHANGE_ME' -Quiet) {
    Write-Host 'В .env остался POSTGRES_PASSWORD=CHANGE_ME...: задайте свой пароль и запустите скрипт снова.' -ForegroundColor Red
    notepad .env
    exit 1
}
if (-not (Test-Path installers) -and -not (Test-Path images.tar)) { throw 'Не найдена папка installers рядом с папкой scripts. Похоже, скачан исходный код репозитория (Code -> Download ZIP), а нужен готовый комплект: GitHub -> Actions -> offline-bundle -> последний зелёный запуск -> Artifacts -> zabbix-offline. См. docs/DEPLOY.md, раздел 2.1.' }
if (-not (Test-Path images.tar)) { throw 'Не найден images.tar в корне комплекта (рядом с папкой scripts).' }

# Проверка контрольных сумм
if (Test-Path SHA256SUMS) {
    Write-Host 'Проверка SHA256SUMS (images.tar большой, подождите) ...'
    $res = @(Test-Sha256Sums (Get-Location).Path (Get-Content -LiteralPath SHA256SUMS -Encoding UTF8))
    if ($res.Count -eq 0) { throw 'SHA256SUMS пуст или в нём нет ни одной строки в формате sha256sum' }
    foreach ($r in $res) {
        if ($r.Status -eq 'Mismatch') { Write-Host "ОШИБКА суммы: $($r.Path)" -ForegroundColor Red }
        elseif ($r.Status -eq 'Missing') { Write-Host "нет файла (пропущен): $($r.Path)" -ForegroundColor Yellow }
    }
    if (@($res | Where-Object Status -eq 'Mismatch').Count) { throw 'Контрольные суммы не совпали: файлы повреждены при копировании, скопируйте комплект заново' }
    Write-Host "Контрольные суммы: проверено файлов $(@($res | Where-Object Status -eq 'Ok').Count)." -ForegroundColor Green
} else {
    Write-Host 'SHA256SUMS не найден: проверка пропущена.' -ForegroundColor Yellow
}

# Docker должен быть запущен
$ErrorActionPreference = 'Continue'
docker info 2>&1 | Out-Null
$dockerOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if (-not $dockerOk) { throw 'Docker не отвечает: запустите Docker Desktop, дождитесь зелёного значка и повторите.' }

docker load -i images.tar
if ($LASTEXITCODE) { throw "docker load завершился с кодом $LASTEXITCODE" }

$cf = @('-f', 'docker-compose.yml')
if (Test-Path docker-compose.map.yml) { $cf += @('-f', 'docker-compose.map.yml') }
docker compose @cf up -d --no-build
if ($LASTEXITCODE) { throw "docker compose up завершился с кодом $LASTEXITCODE" }
docker compose @cf ps
Write-Host 'Первичная настройка: docker compose exec zabbix-server python3 /opt/zbx-tools/post_setup.py'
