#!/usr/bin/env bash
# Скачивает установщики для офлайн-комплекта (нужен интернет). Использование: fetch-installers.sh <папка>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env 2>/dev/null || . ./.env.example; set +a
OUT="${1:?папка назначения}"; mkdir -p "$OUT"
SUM="shasum -a 256"; command -v sha256sum >/dev/null && SUM=sha256sum   # на Mac нет sha256sum
dl() {
  echo ">> $2"
  curl -fL --retry 3 --connect-timeout 30 -o "$OUT/$2" "$1"
  [ -s "$OUT/$2" ] || { echo "пустой файл: $2" >&2; exit 1; }
}

# Docker Desktop (последняя версия на момент сборки; лицензию проверить, docs/DECISIONS.md)
dl "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" "DockerDesktopInstaller.exe"

# WSL (MSI с GitHub Releases microsoft/WSL, последняя стабильная)
# (пустой массив с set -u в bash 3.2 на Mac даёт ошибку, поэтому ${AUTH[@]+...})
AUTH=(); [ -n "${GH_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GH_TOKEN")
WSL_URL=$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} https://api.github.com/repos/microsoft/WSL/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*x64\.msi"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/' || true)
[ -n "$WSL_URL" ] || { echo "не найден wsl x64 msi"; exit 1; }
dl "$WSL_URL" "$(basename "$WSL_URL")"

# VirtualBox - запасной вариант A2, если Hyper-V включить нельзя (docs/DEPLOY.md, 3.7).
# 7.1.18: последний выпуск ветки 7.1; в руководстве хостом указана «Windows 10» без ограничения по сборке
# (проверено по manual ch01 и changelog), Extension Pack не нужен. SHA256 сверяется с официальным SHA256SUMS.
VBOX_VER=7.1.18; VBOX_BUILD=173720
mkdir -p "$OUT/virtualbox"
VBOX_FILE="VirtualBox-${VBOX_VER}-${VBOX_BUILD}-Win.exe"
dl "https://download.virtualbox.org/virtualbox/${VBOX_VER}/${VBOX_FILE}" "virtualbox/${VBOX_FILE}"
curl -fsSL "https://download.virtualbox.org/virtualbox/${VBOX_VER}/SHA256SUMS" -o "$OUT/virtualbox/SHA256SUMS"
( cd "$OUT/virtualbox" && grep -F "${VBOX_FILE}" SHA256SUMS | sed 's/ \*/  /' | $SUM -c - )
echo "de14e4d6572e5a602e5053f3fd8c641356fd377ef9baa813136ae32711d19488  $OUT/virtualbox/${VBOX_FILE}" | $SUM -c -
# Microsoft Visual C++ 2015-2022 Redistributable x64 (нужен VirtualBox 7.x)
dl "https://aka.ms/vs/17/release/vc_redist.x64.exe" "virtualbox/vc_redist.x64.exe"

# Агенты Zabbix для Windows (версия = версии сервера)
B="https://cdn.zabbix.com/zabbix/binaries/stable/7.0/${ZBX_VERSION}"
dl "$B/zabbix_agent2-${ZBX_VERSION}-windows-amd64-openssl.msi" "zabbix_agent2-${ZBX_VERSION}-windows-amd64-openssl.msi"   # Windows 10/11
dl "$B/zabbix_agent-${ZBX_VERSION}-windows-amd64-openssl.msi"  "zabbix_agent-${ZBX_VERSION}-windows-amd64-openssl.msi"    # Windows 7 x64 (классический агент)
dl "$B/zabbix_agent-${ZBX_VERSION}-windows-i386-openssl.msi"   "zabbix_agent-${ZBX_VERSION}-windows-i386-openssl.msi"     # Windows 7 x86

# Браузеры: на Windows 10 LTSC 2019 нет Edge (только IE11, интерфейс Zabbix 7.0 в нём не работает),
# на Windows 7 современный Chrome/Edge не ставится. Firefox ESR: 153 - для Windows 10/11, 115 - последняя ветка для Windows 7.
mkdir -p "$OUT/browsers"
FX="https://download.mozilla.org/?lang=ru&product"
dl "$FX=firefox-esr-msi-latest-ssl&os=win64"    "browsers/Firefox-ESR-win10-11-x64.msi"
dl "$FX=firefox-esr115-msi-latest-ssl&os=win64" "browsers/Firefox-ESR115-win7-x64.msi"
dl "$FX=firefox-esr115-msi-latest-ssl&os=win"   "browsers/Firefox-ESR115-win7-x86.msi"

# WinSCP portable: забирать бэкапы из ВМ по SFTP, если в Windows нет scp
mkdir -p "$OUT/tools"
dl "https://winscp.net/download/WinSCP-6.5.3-Portable.zip" "tools/WinSCP-6.5.3-Portable.zip"
ls -laR "$OUT"
