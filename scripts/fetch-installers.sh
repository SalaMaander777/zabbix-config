#!/usr/bin/env bash
# Скачивает установщики для офлайн-комплекта (нужен интернет). Использование: fetch-installers.sh <папка>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env 2>/dev/null || . ./.env.example; set +a
OUT="${1:?папка назначения}"; mkdir -p "$OUT"
dl() { echo ">> $2"; curl -fL --retry 3 -o "$OUT/$2" "$1"; }

# Docker Desktop (последняя версия на момент сборки; лицензию проверить, docs/DECISIONS.md)
dl "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" "DockerDesktopInstaller.exe"

# WSL (MSI с GitHub Releases microsoft/WSL, последняя стабильная)
AUTH=(); [ -n "${GH_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GH_TOKEN")
WSL_URL=$(curl -fsSL "${AUTH[@]}" https://api.github.com/repos/microsoft/WSL/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*x64\.msi"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$WSL_URL" ] || { echo "не найден wsl x64 msi"; exit 1; }
dl "$WSL_URL" "$(basename "$WSL_URL")"

# Агенты Zabbix для Windows (версия = версии сервера)
B="https://cdn.zabbix.com/zabbix/binaries/stable/7.0/${ZBX_VERSION}"
dl "$B/zabbix_agent2-${ZBX_VERSION}-windows-amd64-openssl.msi" "zabbix_agent2-${ZBX_VERSION}-windows-amd64-openssl.msi"   # Windows 10/11
dl "$B/zabbix_agent-${ZBX_VERSION}-windows-amd64-openssl.msi"  "zabbix_agent-${ZBX_VERSION}-windows-amd64-openssl.msi"    # Windows 7 x64 (классический агент)
dl "$B/zabbix_agent-${ZBX_VERSION}-windows-i386-openssl.msi"   "zabbix_agent-${ZBX_VERSION}-windows-i386-openssl.msi"     # Windows 7 x86
ls -la "$OUT"
