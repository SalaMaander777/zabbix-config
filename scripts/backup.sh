#!/usr/bin/env bash
# Ежедневный бэкап (Linux/ВМ): pg_dump + экспорт конфигурации в ./backups, хранится 30 копий.
set -euo pipefail
cd "$(dirname "$0")/.."
ts=$(date +%Y%m%d-%H%M)
docker compose exec -T postgres sh -c "pg_dump -U \$POSTGRES_USER -Fc -f /backups/zabbix-$ts.dump \$POSTGRES_DB"
docker compose exec -T zabbix-server python3 /opt/zbx-tools/export_config.py
# ротация: 30 последних дампов и 30 последних экспортов конфигурации
{ ls -1t backups/zabbix-*.dump 2>/dev/null | tail -n +31 | xargs -r rm -f --; } || true
{ ls -1d backups/config-* 2>/dev/null | sort -r | tail -n +31 | xargs -r rm -rf --; } || true
echo "backup ok: backups/zabbix-$ts.dump"
