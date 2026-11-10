#!/usr/bin/env bash
# Первый запуск: загрузка образов, .env, запуск стека, post_setup.
set -euo pipefail
cd /opt/zabbix
echo "[firstboot] docker load"
docker load -i /opt/zabbix/images.tar
if [ ! -f .env ]; then
  cp .env.example .env
  pw=$(python3 -c 'import secrets;print(secrets.token_hex(16))')
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
  echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.map.yml' >> .env
  chmod 600 .env
fi
mkdir -p backups; chmod 777 backups
echo "[firstboot] compose up"
docker compose up -d --no-build
echo "[firstboot] ждём API"
ok=0
for _ in $(seq 1 120); do
  if curl -fsS -H 'Content-Type: application/json-rpc' \
      -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
      http://127.0.0.1/api_jsonrpc.php >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "[firstboot] API не поднялся за 10 минут"; docker compose ps; exit 1; }
sleep 20
echo "[firstboot] post_setup"
for i in 1 2 3 4 5; do
  if docker compose exec -T zabbix-server python3 /opt/zbx-tools/post_setup.py; then ok=2; break; fi
  echo "[firstboot] post_setup попытка $i не удалась, повтор"; sleep 20
done
[ "$ok" = 2 ] || { echo "[firstboot] post_setup не выполнен"; exit 1; }
touch /var/lib/zabbix-firstboot.done
echo "[firstboot] готово"
