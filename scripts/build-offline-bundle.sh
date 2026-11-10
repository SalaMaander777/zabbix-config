#!/usr/bin/env bash
# Запускать на Mac (есть интернет). Собирает dist/zabbix-offline-<дата>/ для переноса на Windows.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
export DOCKER_DEFAULT_PLATFORM=linux/amd64

OUT="dist/zabbix-offline-$(date +%Y%m%d)"
mkdir -p "$OUT"

echo ">> pull (linux/amd64)"
docker pull --platform linux/amd64 "$PG_IMAGE"
docker pull --platform linux/amd64 "zabbix/zabbix-server-pgsql:alpine-${ZBX_VERSION}"
docker pull --platform linux/amd64 "zabbix/zabbix-web-nginx-pgsql:alpine-${ZBX_VERSION}"
docker pull --platform linux/amd64 "zabbix/zabbix-agent2:alpine-${ZBX_VERSION}"

echo ">> build своего образа сервера (python3)"
docker compose build zabbix-server

echo ">> build карты (zabbix-map)"
docker compose -f docker-compose.yml -f docker-compose.map.yml build zabbix-map

echo ">> проверка python3 и архитектуры"
docker run --rm --platform linux/amd64 --entrypoint python3 "zabbix-server-custom:${ZBX_VERSION}" --version
docker image inspect "zabbix-server-custom:${ZBX_VERSION}" --format '{{.Architecture}}' | grep -qx amd64

echo ">> save"
docker save -o "$OUT/images.tar" \
  "$PG_IMAGE" \
  "zabbix-server-custom:${ZBX_VERSION}" \
  "zabbix/zabbix-web-nginx-pgsql:alpine-${ZBX_VERSION}" \
  "zabbix/zabbix-agent2:alpine-${ZBX_VERSION}" \
  "zabbix-map:local"

echo ">> файлы стека"
cp docker-compose.yml docker-compose.map.yml .env.example "$OUT/"
cp -R server zabbix templates scripts docs "$OUT/"
mkdir -p "$OUT/map/data"
cp -R map/app map/static map/Dockerfile map/fetch-tiles.sh "$OUT/map/"
if [ -f map/data/moscow.pmtiles ] || map/fetch-tiles.sh; then
  cp map/data/moscow.pmtiles "$OUT/map/data/"
else
  echo "ВНИМАНИЕ: тайлы карты не скачаны, карта будет без подложки (см. docs/MAPS.md)" >&2
fi
mkdir -p "$OUT/backups" "$OUT/installers"
[ "${SKIP_INSTALLERS:-0}" = 1 ] || scripts/fetch-installers.sh "$OUT/installers"

# Секреты в комплект не попадают: .env (пароли) никогда не копируется, только .env.example.
rm -f "$OUT/.env"
find "$OUT" -name '.env' -o -name '*.pem' -o -name '*.key' | grep . && { echo "в комплекте найден секретный файл" >&2; exit 1; } || true

SUM="shasum -a 256"; command -v sha256sum >/dev/null && SUM=sha256sum
# SHA256SUMS покрывает ВСЕ файлы комплекта, включая installers/*, images.tar и docs/.
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 $SUM > SHA256SUMS )
[ -s "$OUT/images.tar" ] || { echo "images.tar пуст" >&2; exit 1; }
echo "Размеры:"; du -sh "$OUT"/* | sort -h
echo "Готово: $OUT  (контрольные суммы: SHA256SUMS, файлов: $(wc -l < "$OUT/SHA256SUMS"))"
