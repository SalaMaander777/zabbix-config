#!/usr/bin/env bash
# Скачивает векторные тайлы Москвы и области (OpenStreetMap, сборка Protomaps) в map/data/moscow.pmtiles.
# Нужен интернет. Запускать на машине сборки комплекта, не на объекте.
# Данные (c) участники OpenStreetMap, лицензия ODbL: https://www.openstreetmap.org/copyright
set -euo pipefail
cd "$(dirname "$0")"

PMTILES_VERSION="${PMTILES_VERSION:-1.30.1}"
BBOX="${BBOX:-35.1,54.2,40.3,56.98}"     # Москва и Московская область
MAXZOOM="${MAXZOOM:-13}"
OUT="${1:-data/moscow.pmtiles}"
mkdir -p "$(dirname "$OUT")" .cache

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  ASSET="Linux_x86_64" ;;
  Linux-aarch64|Linux-arm64) ASSET="Linux_arm64" ;;
  Darwin-arm64)  ASSET="Darwin_arm64" ;;
  Darwin-x86_64) ASSET="Darwin_x86_64" ;;
  *) echo "Неподдерживаемая платформа для go-pmtiles" >&2; exit 1 ;;
esac

BIN=".cache/pmtiles-$PMTILES_VERSION"
if [ ! -x "$BIN" ]; then
  echo ">> go-pmtiles v$PMTILES_VERSION ($ASSET)"
  curl -fsSL -o .cache/pmtiles.tgz \
    "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_${ASSET}.tar.gz"
  tar -xzf .cache/pmtiles.tgz -C .cache pmtiles
  mv .cache/pmtiles "$BIN"; rm -f .cache/pmtiles.tgz
fi

# Дневная сборка Protomaps: берём самую свежую из существующих за последние 14 дней.
URL=""
for i in $(seq 0 14); do
  D="$(date -u -d "-$i day" +%Y%m%d 2>/dev/null || date -u -v-"$i"d +%Y%m%d)"
  if curl -fsI "https://build.protomaps.com/$D.pmtiles" >/dev/null 2>&1; then
    URL="https://build.protomaps.com/$D.pmtiles"; break
  fi
done
[ -n "$URL" ] || { echo "Не найдена сборка на build.protomaps.com" >&2; exit 1; }

echo ">> extract $URL bbox=$BBOX maxzoom=$MAXZOOM"
"$BIN" extract "$URL" "$OUT.part" --bbox="$BBOX" --maxzoom="$MAXZOOM"
mv "$OUT.part" "$OUT"
ls -la "$OUT"
