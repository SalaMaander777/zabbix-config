#!/usr/bin/env bash
# Ежедневный бэкап (Linux/ВМ): pg_dump + экспорт конфигурации в ./backups, хранится 30 копий.
# Коды выхода: 0 - всё сделано; 1 - не создан дамп БД; 2 - дамп есть, экспорт конфигурации не удался
# (чаще всего ZBX_API_PASSWORD в .env не совпадает с паролем Admin: sudo zbx-setapipass); 3 - уже выполняется другой бэкап.
set -euo pipefail
cd "$(dirname "$0")/.."
exec 9>"${TMPDIR:-/tmp}/zabbix-backup.lock"
flock -n 9 || { echo "backup: уже выполняется"; exit 3; }
ts=$(date +%Y%m%d-%H%M)
dump=backups/zabbix-$ts.dump
if ! docker compose exec -T postgres sh -c "pg_dump -U \$POSTGRES_USER -Fc -f /backups/zabbix-$ts.dump \$POSTGRES_DB" \
   || ! docker compose exec -T postgres pg_restore -l "/backups/zabbix-$ts.dump" >/dev/null; then
  echo "backup: дамп БД не создан или повреждён" >&2
  rm -f -- "$dump"
  exit 1
fi
rc=0
docker compose exec -T zabbix-server python3 /opt/zbx-tools/export_config.py || { echo "backup: экспорт конфигурации не удался (проверьте ZBX_API_PASSWORD в .env)" >&2; rc=2; }
# ротация: 30 последних дампов и 30 последних экспортов конфигурации
{ ls -1t backups/zabbix-*.dump 2>/dev/null | tail -n +31 | xargs -r rm -f --; } || true
{ ls -1d backups/config-* 2>/dev/null | sort -r | tail -n +31 | xargs -r rm -rf --; } || true
echo "backup: $dump (код $rc)"
exit $rc
