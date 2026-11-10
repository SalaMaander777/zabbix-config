#!/usr/bin/env bash
# Первый запуск: загрузка образов, .env, запуск стека, post_setup. Повторяем: при сбое можно перезапустить юнит.
set -euo pipefail
umask 077
cd /opt/zabbix

# подкачка: ОЗУ ВМ всего 5 ГБ, swapfile 2 ГБ страхует от OOM при пиках (не критично, ошибки не фатальны)
if ! swapon --show=NAME --noheadings | grep -q .; then
  { [ -f /swapfile ] || { fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048; chmod 600 /swapfile; mkswap /swapfile; }
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=-2 0 0' >> /etc/fstab
    swapon /swapfile; } || echo "[firstboot] swapfile не создан, продолжаем без него"
fi

if [ ! -f /var/lib/zabbix-images.loaded ]; then
  echo "[firstboot] docker load"
  docker load -i /opt/zabbix/images.tar
  touch /var/lib/zabbix-images.loaded
fi
if [ ! -f .env ]; then
  tmp=$(mktemp -p /opt/zabbix .env.XXXXXX)
  pw=$(python3 -c 'import secrets;print(secrets.token_hex(16))')
  sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env.example > "$tmp"
  echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.map.yml' >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" .env
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
