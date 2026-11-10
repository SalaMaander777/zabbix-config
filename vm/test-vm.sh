#!/usr/bin/env bash
# Тест собранной ВМ в QEMU (UEFI, как Hyper-V Gen 2) на копии-оверлее. Состояние теста в образ не попадает.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$PWD/vm/work
BASE=$WORK/final.qcow2
[ -f "$BASE" ] || { echo "нет $BASE"; exit 1; }
sudo apt-get install -y qemu-system-x86 ovmf >/dev/null
sudo chmod 666 /dev/kvm || true

cd "$WORK"
rm -f overlay.qcow2 serial.log
qemu-img create -f qcow2 -b final.qcow2 -F qcow2 overlay.qcow2
CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
[ -f "$CODE" ] || { CODE=/usr/share/OVMF/OVMF_CODE.fd; VARS=/usr/share/OVMF/OVMF_VARS.fd; }
cp "$VARS" vars.fd
ACCEL=kvm; [ -w /dev/kvm ] || ACCEL=tcg

qemu-system-x86_64 -machine "q35,accel=$ACCEL" -cpu max -m 4096 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$CODE" -drive "if=pflash,format=raw,file=vars.fd" \
  -drive file=overlay.qcow2,if=virtio,format=qcow2 \
  -nic user,model=virtio-net-pci,hostfwd=tcp::8080-:80,hostfwd=tcp::8081-:8081 \
  -display none -serial file:serial.log -daemonize -pidfile qemu.pid

api() { # api <json> [token]
  curl -fsS -m 20 -H 'Content-Type: application/json-rpc' ${2:+-H "Authorization: Bearer $2"} -d "$1" http://localhost:8080/api_jsonrpc.php
}
ok=0
for i in $(seq 1 120); do
  if api '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' >/dev/null 2>&1; then ok=1; break; fi
  sleep 10
done
if [ "$ok" != 1 ]; then echo "API не ответил за 20 минут"; tail -n 80 serial.log; exit 1; fi
echo "API ответил через ~$((i*10)) c"
# firstboot (post_setup) может ещё идти: ждём шаблоны до 10 минут
for i in $(seq 1 60); do
  tok=$(api '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result",""))' || true)
  if [ -n "${tok:-}" ]; then
    res=$(api '{"jsonrpc":"2.0","method":"template.get","params":{"output":["host"]},"id":2}' "$tok")
    miss=0
    for t in 'Infinet R5000 SNMP' 'ESMD ICMP and TCP' 'EB500 ICMP and SCPI'; do
      echo "$res" | python3 -c 'import sys,json;t=sys.argv[1];sys.exit(0 if any(x["host"]==t for x in json.load(sys.stdin)["result"]) else 1)' "$t" || miss=1
    done
    [ "$miss" = 0 ] && { echo "шаблоны на месте"; curl -fsS -m 20 http://localhost:8081/healthz; echo; kill "$(cat qemu.pid)"; exit 0; }
  fi
  sleep 10
done
echo "шаблоны не найдены"; tail -n 80 serial.log; exit 1
