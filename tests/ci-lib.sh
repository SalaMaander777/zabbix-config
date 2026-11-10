# Общие функции CI (source tests/ci-lib.sh)
WEB="http://localhost:${WEB_PORT:-80}/api_jsonrpc.php"
wait_api() {
  for i in $(seq 1 90); do
    curl -fsS -H 'Content-Type: application/json-rpc' \
      -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' "$WEB" 2>/dev/null | grep -q '"result"' && return 0
    sleep 5
  done
  echo "API Zabbix не поднялся" >&2; return 1
}
# Сервер жив, если принимает команду runtime control
wait_server() {
  for i in $(seq 1 60); do
    docker compose exec -T zabbix-server zabbix_server -R config_cache_reload 2>&1 | grep -q "forwarded successfully" && return 0
    sleep 5
  done
  echo "zabbix_server не отвечает на runtime control" >&2; return 1
}
wait_stack() { wait_api && wait_server; }
py() { docker compose exec -T zabbix-server python3 "$@"; }
