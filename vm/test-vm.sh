#!/usr/bin/env bash
# Тест собранной ВМ в QEMU на копии-оверлее. Состояние теста (ключ ssh, sudo без пароля, снятие chage) пишется
# ТОЛЬКО в overlay.qcow2; поставляемые final.raw / VDI / VHDX не меняются.
#   test-vm.sh uefi  (по умолчанию) - UEFI + virtio, как Hyper-V Gen 2; диск final.raw
#   test-vm.sh bios                 - BIOS (SeaBIOS, без OVMF) + AHCI + e1000, как VirtualBox; диск - сам VDI из поставки
# Этапы: аудит образа до загрузки (guestfish) -> загрузка -> API и шаблоны -> внутреннее состояние по ssh ->
# backup.sh, ротация, pg_restore -> zbx-netconfig -> смена пароля Admin + zbx-setapipass -> перезагрузка без firstboot.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=${1:-uefi}
WORK=$PWD/vm/work
if [ "$MODE" = bios ]; then BASE=$WORK/zabbix-vm-debian12.vdi; BFMT=vdi; else BASE=$WORK/final.raw; BFMT=raw; fi
[ -f "$BASE" ] || { echo "нет $BASE"; exit 1; }
echo "== режим теста: $MODE, диск $BASE"
sudo apt-get install -y qemu-system-x86 ovmf openssh-client libguestfs-tools >/dev/null
sudo chmod 666 /dev/kvm || true
sudo chmod 0644 /boot/vmlinuz* || true
export LIBGUESTFS_BACKEND=direct

cd "$WORK"
rm -f overlay.qcow2 serial.log test_key test_key.pub
qemu-img create -f qcow2 -b "$BASE" -F "$BFMT" overlay.qcow2
BASE_SUM=$(sha256sum "$BASE" | cut -d' ' -f1)

fail() {
  echo "ОШИБКА: $*"; tail -n 60 serial.log || true
  echo "--- журнал ВМ (warning+) ---"; timeout 30 ssh "${SSHO[@]}" zbxadmin@127.0.0.1 "sudo journalctl -b --no-pager -p warning | tail -n 80; sudo systemctl --failed --no-pager" 2>&1 </dev/null || true
  exit 1
}
SSHO=(-i test_key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=15)
chk() { # chk <описание> <команда...>: проверка в хосте теста
  local d=$1; shift
  if "$@"; then echo "  ok: $d"; else fail "$d"; fi
}

# ---------- 1. аудит образа до загрузки (на оверлее) ----------
echo "== аудит поставляемого образа"
rm -rf audit; mkdir audit
gf() { sudo -E guestfish --ro --format=qcow2 -a overlay.qcow2 -i "$@"; }
gf <<'EOT' > audit/out.txt
echo SSHKEYS
glob-expand /etc/ssh/ssh_host_*
echo MACHINEID
filesize /etc/machine-id
echo ENV
is-file /opt/zabbix/.env
echo DONE
is-file /var/lib/zabbix-firstboot.done
echo LOADED
is-file /var/lib/zabbix-images.loaded
echo SWAP
is-file /swapfile
echo HIST
is-file /root/.bash_history
echo END
EOT
sudo -E guestfish --ro --format=qcow2 -a overlay.qcow2 -i download /etc/shadow audit/shadow
sudo -E guestfish --ro --format=qcow2 -a overlay.qcow2 -i download /etc/passwd audit/passwd
sudo chown -R "$(id -u):$(id -g)" audit
sec() { awk -v s="$1" '$0==s{f=1;next} /^[A-Z]+$/{f=0} f' audit/out.txt; }
chk "в образе нет ключей хоста ssh" test -z "$(sec SSHKEYS)"
chk "machine-id пуст (уникальный создаётся при первой загрузке)" test "$(sec MACHINEID)" = 0
chk "нет .env (пароль БД создаётся при первой загрузке)" test "$(sec ENV)" = false
chk "нет маркера firstboot.done" test "$(sec DONE)" = false
chk "нет маркера загрузки образов" test "$(sec LOADED)" = false
chk "нет bash_history root" test "$(sec HIST)" = false
chk "zbxadmin: смена пароля при первом входе (chage -d 0)" awk -F: '$1=="zbxadmin"{exit !($3=="0")}' audit/shadow
chk "root заблокирован" awk -F: '$1=="root"{exit !($2 ~ /^[!*]/)}' audit/shadow
ZUID=$(awk -F: '$1=="zbxadmin"{print $3}' audit/passwd); ZGID=$(awk -F: '$1=="zbxadmin"{print $4}' audit/passwd)

# ---------- 2. ключ и тестовые правки ТОЛЬКО в оверлее ----------
ssh-keygen -q -t ed25519 -N '' -f test_key
awk -F: -v OFS=: '$1=="zbxadmin"{$3="20000"; $5="99999"} {print}' audit/shadow > audit/shadow.new
echo "zbxadmin ALL=(ALL) NOPASSWD:ALL" > audit/zz-test
sudo -E guestfish --rw --format=qcow2 -a overlay.qcow2 -i <<EOT
upload audit/shadow.new /etc/shadow
chmod 0640 /etc/shadow
chown 0 42 /etc/shadow
mkdir-p /home/zbxadmin/.ssh
upload test_key.pub /home/zbxadmin/.ssh/authorized_keys
chmod 0700 /home/zbxadmin/.ssh
chmod 0600 /home/zbxadmin/.ssh/authorized_keys
chown $ZUID $ZGID /home/zbxadmin/.ssh
chown $ZUID $ZGID /home/zbxadmin/.ssh/authorized_keys
upload audit/zz-test /etc/sudoers.d/zz-test
chmod 0440 /etc/sudoers.d/zz-test
EOT
sudo chown "$(id -u):$(id -g)" overlay.qcow2

# ---------- 3. запуск ----------
ACCEL=kvm; [ -w /dev/kvm ] || ACCEL=tcg
FWD="hostfwd=tcp::8080-:80,hostfwd=tcp::8081-:8081,hostfwd=tcp::2222-:22"
if [ "$MODE" = bios ]; then
  # как VirtualBox: чипсет i440FX (PIIX3), BIOS, диск на контроллере AHCI (SATA), сетевая карта Intel e1000 (82540EM)
  qemu-system-x86_64 -machine "pc,accel=$ACCEL" -cpu max -m 4096 -smp 2 \
    -device ahci,id=ahci0 -drive file=overlay.qcow2,if=none,id=hd0,format=qcow2 -device ide-hd,drive=hd0,bus=ahci0.0 \
    -netdev "user,id=n0,$FWD" -device e1000,netdev=n0 \
    -display none -serial file:serial.log -daemonize -pidfile qemu.pid
else
  CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
  [ -f "$CODE" ] || { CODE=/usr/share/OVMF/OVMF_CODE.fd; VARS=/usr/share/OVMF/OVMF_VARS.fd; }
  cp "$VARS" vars.fd
  qemu-system-x86_64 -machine "q35,accel=$ACCEL" -cpu max -m 4096 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$CODE" -drive "if=pflash,format=raw,file=vars.fd" \
    -drive file=overlay.qcow2,if=virtio,format=qcow2 \
    -nic "user,model=virtio-net-pci,$FWD" \
    -display none -serial file:serial.log -daemonize -pidfile qemu.pid
fi

api() { # api <json> [token]
  curl -fsS -m 20 -H 'Content-Type: application/json-rpc' ${2:+-H "Authorization: Bearer $2"} -d "$1" http://localhost:8080/api_jsonrpc.php
}
login() { # login <пароль> -> токен
  api "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"Admin\",\"password\":\"$1\"},\"id\":1}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result",""))'
}
wait_api() { # wait_api <число попыток по 10 с>
  for i in $(seq 1 "$1"); do
    api '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' >/dev/null 2>&1 && { echo "API ответил через ~$((i*10)) c"; return 0; }
    sleep 10
  done
  fail "API не ответил"
}
vm() { ssh -n "${SSHO[@]}" zbxadmin@127.0.0.1 "$@"; }
vmin() { ssh "${SSHO[@]}" zbxadmin@127.0.0.1 "$@"; }   # stdin передаётся в ВМ
# vmchk <описание> <команда в ВМ от root>
vmchk() { local d=$1; shift; if out=$(vm "sudo bash -c $(printf '%q' "$*")" 2>&1); then echo "  ok: $d"; else echo "$out"; fail "в ВМ: $d"; fi; }
wait_ssh() {
  for _ in $(seq 1 60); do vm true 2>/dev/null && return 0; sleep 5; done
  fail "ssh не отвечает"
}

wait_api 120
# firstboot (post_setup) может ещё идти: ждём шаблоны до 10 минут
tok=""
for i in $(seq 1 60); do
  tok=$(login zabbix 2>/dev/null || true)
  if [ -n "$tok" ]; then
    res=$(api '{"jsonrpc":"2.0","method":"template.get","params":{"output":["host"]},"id":2}' "$tok")
    miss=0
    for t in 'Infinet R5000 SNMP' 'ESMD ICMP and TCP' 'EB500 ICMP and SCPI'; do
      echo "$res" | python3 -c 'import sys,json;t=sys.argv[1];sys.exit(0 if any(x["host"]==t for x in json.load(sys.stdin)["result"]) else 1)' "$t" || miss=1
    done
    [ "$miss" = 0 ] && break
  fi
  sleep 10
done
[ "${miss:-1}" = 0 ] || fail "шаблоны не найдены"
echo "шаблоны на месте"; curl -fsS -m 20 http://localhost:8081/healthz; echo

# ---------- 4. внутреннее состояние ----------
echo "== внутреннее состояние ВМ (ssh)"
wait_ssh
# ждём завершения firstboot (маркер создаётся последним)
for _ in $(seq 1 60); do vm 'test -f /var/lib/zabbix-firstboot.done' 2>/dev/null && break; sleep 10; done
vmchk "firstboot завершён (маркер)" 'test -f /var/lib/zabbix-firstboot.done'
for u in docker chrony zabbix-stack ssh systemd-networkd systemd-resolved; do vmchk "$u active" "systemctl is-active $u"; done
vmchk "zabbix-firstboot не в состоянии failed" '! systemctl is-failed zabbix-firstboot'
vmchk "zabbix-backup.timer включён и активен" 'systemctl is-enabled zabbix-backup.timer && systemctl is-active zabbix-backup.timer'
# допустимы отказы только демонов Hyper-V (в QEMU/VirtualBox нет их устройств)
failed=$(vm "systemctl --failed --no-legend --plain | awk '{print \$1}'" || true)
echo "упавшие юниты: ${failed:-нет}"
bad=$(echo "$failed" | grep -Ev '^(hv[-_a-z]*|hyperv[-_a-z]*)\.service$|^$' || true)
[ -z "$bad" ] || fail "упавшие юниты: $bad"
vmchk "chronyc tracking отвечает" 'chronyc tracking'
vmchk "вне Hyper-V refclock PHC не подключён" '! grep -q "^refclock" /etc/chrony/conf.d/hyperv.conf'
vmchk "ветка Hyper-V zbx-chrony-hv пишет refclock PHC" 'ZBX_PTP_DEV=/dev/null ZBX_CHRONY_CONF=/tmp/hv.conf /usr/local/sbin/zbx-chrony-hv && grep -q "^refclock PHC /dev/null" /tmp/hv.conf'
vmchk ".env: права 600, владелец root" '[ "$(stat -c "%a %U" /opt/zabbix/.env)" = "600 root" ]'
vmchk ".env: COMPOSE_FILE с картой" 'grep -qx "COMPOSE_FILE=docker-compose.yml:docker-compose.map.yml" /opt/zabbix/.env'
vmchk ".env: случайный пароль БД (32 hex)" 'grep -Eqx "POSTGRES_PASSWORD=[0-9a-f]{32}" /opt/zabbix/.env'
vmchk "4 контейнера работают (postgres, zabbix-server, zabbix-web, zabbix-map)" '[ "$(cd /opt/zabbix && docker compose ps --status running --services | sort | tr "\n" " ")" = "postgres zabbix-map zabbix-server zabbix-web " ]'
vmchk "docker: журнал json-file с ротацией" 'docker info --format "{{.LoggingDriver}}" | grep -qx json-file && grep -q max-size /etc/docker/daemon.json'
vmchk "ключи хоста ssh созданы при первой загрузке" 'ls /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key'
vmchk "machine-id создан" '[ "$(wc -c < /etc/machine-id)" -ge 32 ]'
vmchk "часовой пояс Europe/Moscow" '[ "$(timedatectl show -p Timezone --value)" = Europe/Moscow ]'
vmchk "журнал постоянный (/var/log/journal) с лимитом" 'test -d /var/log/journal && journalctl --disk-usage && grep -q SystemMaxUse /etc/systemd/journald.conf.d/zbx.conf'
vmchk "swapfile активен" 'swapon --show=NAME --noheadings | grep -qx /swapfile'
vmchk "корневая ФС расширена до диска (>= 36 ГБ)" '[ "$(df -BG --output=size / | tail -n1 | tr -dc 0-9)" -ge 36 ]'
vmchk "apt-daily выключены (офлайн)" '[ "$(systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer | sort -u)" = masked ]'
vmchk "zbxadmin в группах sudo, docker" 'id -nG zbxadmin | tr " " "\n" | grep -qx sudo && id -nG zbxadmin | tr " " "\n" | grep -qx docker'
vmchk "вход root по паролю закрыт" '[ "$(passwd -S root | cut -d" " -f2)" = L ]'
vmchk "образ: нет секретов (.env.example без боевого пароля, нет истории)" '! test -f /root/.bash_history && grep -q "^POSTGRES_PASSWORD=CHANGE_ME" /opt/zabbix/.env.example'

echo "== backup.sh, ротация, восстановление"
# старые «лишние» копии: 32 дампа и 32 каталога конфигурации (ротация оставляет 30)
vmchk "подготовка файлов для проверки ротации" 'cd /opt/zabbix/backups && for n in $(seq 10 41); do touch -d "@$((946684800+n*86400))" zabbix-20000101-00$n.dump; mkdir -p config-2000-01-$n; done; true'
vmchk "backup.sh завершился с кодом 0" '/opt/zabbix/scripts/backup.sh'
vmchk "дамп создан, не пустой, читается pg_restore -l" 'f=$(ls -1t /opt/zabbix/backups/zabbix-2*.dump | head -n1); test -s "$f" && cd /opt/zabbix && docker compose exec -T postgres pg_restore -l /backups/$(basename $f) | grep -q "TABLE DATA"'
vmchk "экспорт конфигурации config-* содержит шаблоны" 'grep -lq "Infinet R5000 SNMP" /opt/zabbix/backups/config-20*/*.json'
vmchk "ротация: дампов <= 30 и свежий на месте" 'cd /opt/zabbix/backups; [ "$(ls zabbix-*.dump | wc -l)" -le 30 ] && [ ! -e zabbix-20000101-0010.dump ] && [ -e zabbix-20000101-0041.dump ] && ! ls -1t zabbix-*.dump | head -n1 | grep -q 20000101 && [ "$(ls -d config-* | wc -l)" -le 30 ] && [ ! -e config-2000-01-10 ] && [ -e config-2000-01-41 ]'
vmchk "backup.service (как по таймеру) выполняется" 'systemctl start zabbix-backup.service'
# восстановление: команды из docs/HYPERV-VM.md
DUMP=$(vm 'ls -1t /opt/zabbix/backups/zabbix-2*.dump | head -n1 | xargs basename')
echo "восстановление из $DUMP"
vmchk "pg_restore --clean --if-exists (как в документации)" "cd /opt/zabbix && docker compose stop zabbix-server zabbix-web && docker compose exec -T postgres sh -c 'pg_restore -U \$POSTGRES_USER -d \$POSTGRES_DB --clean --if-exists /backups/$DUMP' && docker compose start zabbix-server zabbix-web"
wait_api 60
tok=$(login zabbix); [ -n "$tok" ] || fail "после восстановления вход Admin не работает"
echo "  ok: после восстановления API и вход работают"

echo "== zbx-netconfig"
vmchk "--static: файл networkd" 'zbx-netconfig --static 192.168.50.10/24 --gw 192.168.50.1 --dns "192.168.50.2 1.1.1.1" --ntp ntp.example.org --no-apply --net-file /tmp/t.network --ntp-file /tmp/t.sources >/dev/null && grep -qx "Name=e\*" /tmp/t.network && grep -qx "Address=192.168.50.10/24" /tmp/t.network && grep -qx "Gateway=192.168.50.1" /tmp/t.network && [ "$(grep -c "^DNS=" /tmp/t.network)" = 2 ] && grep -qx "DNS=1.1.1.1" /tmp/t.network && ! grep -q "^DHCP=" /tmp/t.network && grep -qx "server ntp.example.org iburst" /tmp/t.sources'
vmchk "--dhcp: файл совпадает с поставляемым" 'zbx-netconfig --dhcp --no-apply --net-file /tmp/d.network >/dev/null && cmp /tmp/d.network /etc/systemd/network/10-zbx-dhcp.network'
vmchk "интерактивный режим (DHCP)" 'printf "1\n\n" | zbx-netconfig --no-apply --net-file /tmp/i.network >/dev/null && cmp /tmp/i.network /etc/systemd/network/10-zbx-dhcp.network'
vmchk "неверные данные отклоняются" '! zbx-netconfig --static 999.1.1.1/24 --gw 1.1.1.1 --no-apply --net-file /tmp/x.network 2>/dev/null && ! zbx-netconfig --static 10.0.2.15/24 --gw 10.9.9.9 --no-apply --net-file /tmp/x.network 2>/dev/null && ! zbx-netconfig --static 10.0.2.15 --gw 10.0.2.2 --no-apply --net-file /tmp/x.network 2>/dev/null'
# применение: тот же адрес, что у QEMU (10.0.2.15), но статикой; затем возврат к DHCP. Сессия ssh может прерваться, поэтому через systemd-run
vm 'sudo systemd-run --no-block --unit=zbx-nc-static zbx-netconfig --static 10.0.2.15/24 --gw 10.0.2.2 --dns 10.0.2.3 --ntp 10.0.2.2' >/dev/null
sleep 15; wait_ssh
vmchk "статика применена без перезагрузки (адрес без dynamic, маршрут по умолчанию)" 'ip -4 addr show scope global | grep "10.0.2.15/24" | grep -vq dynamic && ip route | grep -q "default via 10.0.2.2"'
vmchk "NTP-источник попал в chrony" 'chronyc -n sources | grep -q 10.0.2.2'
vm 'sudo systemd-run --no-block --unit=zbx-nc-dhcp zbx-netconfig --dhcp' >/dev/null
sleep 15; wait_ssh
vmchk "возврат к DHCP (адрес dynamic)" 'ip -4 addr show scope global | grep "10.0.2.15/24" | grep -q dynamic'
tok=$(login zabbix); [ -n "$tok" ] || fail "API недоступен после смены сети"

echo "== смена пароля Admin и ZBX_API_PASSWORD"
NEWPW='Zbx-Test-12345'
uid=$(api '{"jsonrpc":"2.0","method":"user.get","params":{"filter":{"username":"Admin"},"output":["userid"]},"id":3}' "$tok" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["userid"])')
api "{\"jsonrpc\":\"2.0\",\"method\":\"user.update\",\"params\":{\"userid\":\"$uid\",\"passwd\":\"$NEWPW\",\"current_passwd\":\"zabbix\"},\"id\":4}" "$tok" | grep -q '"result"' || fail "не удалось сменить пароль Admin"
if vm 'sudo /opt/zabbix/scripts/backup.sh' >/dev/null 2>&1; then fail "backup.sh прошёл со старым паролем в .env (ожидали код 2)"; else echo "  ok: с устаревшим .env backup.sh завершается ошибкой"; fi
vmchk "zbx-setapipass отклоняет неверный пароль" '! echo wrong-password | zbx-setapipass'
echo "$NEWPW" | vmin 'sudo zbx-setapipass' >/dev/null || fail "zbx-setapipass"
vmchk ".env обновлён, права 600" '[ "$(stat -c %a /opt/zabbix/.env)" = 600 ] && grep -q "^ZBX_API_PASSWORD=" /opt/zabbix/.env && grep -qx "COMPOSE_FILE=docker-compose.yml:docker-compose.map.yml" /opt/zabbix/.env'
wait_api 30
vmchk "backup.sh работает с новым паролем" 'sleep 5; /opt/zabbix/scripts/backup.sh'
vmchk "карта отвечает после пересоздания" 'curl -fsS -m 20 http://127.0.0.1:8081/healthz'
vmchk "все 4 контейнера работают после пересоздания" '[ "$(cd /opt/zabbix && docker compose ps --status running --services | wc -l)" = 4 ]'

# ---------- 5. перезагрузка ----------
echo "== перезагрузка ВМ"
BOOT1=$(vm 'cat /proc/sys/kernel/random/boot_id')
KEYS1=$(vm 'sudo sha256sum /etc/ssh/ssh_host_ed25519_key.pub /etc/machine-id | awk "{print \$1}"')
vm 'sudo systemctl reboot' >/dev/null 2>&1 || true
BOOT2=$BOOT1
for _ in $(seq 1 120); do   # ssh какое-то время отвечает ещё в старой загрузке: ждём смены boot_id
  sleep 5
  BOOT2=$(vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || echo "$BOOT1")
  [ "$BOOT2" != "$BOOT1" ] && break
done
[ "$BOOT1" != "$BOOT2" ] || fail "ВМ не перезагрузилась"
wait_api 90
KEYS2=$(vm 'sudo sha256sum /etc/ssh/ssh_host_ed25519_key.pub /etc/machine-id | awk "{print \$1}"')
[ "$KEYS1" = "$KEYS2" ] || fail "ключ хоста ssh или machine-id изменились после перезагрузки"
echo "  ok: ключ хоста и machine-id стабильны"
vmchk "после перезагрузки firstboot не запускался (условие не выполнено, нет записей в журнале загрузки)" '[ "$(systemctl show -p ConditionResult --value zabbix-firstboot)" = no ] && ! journalctl -b -u zabbix-firstboot --no-pager | grep -q "docker load"'
vmchk "zabbix-stack, docker, chrony active после перезагрузки" 'systemctl is-active zabbix-stack docker chrony >/dev/null'
vmchk "swap после перезагрузки" 'swapon --show=NAME --noheadings | grep -qx /swapfile'
vmchk "4 контейнера поднялись сами" 'for i in $(seq 1 30); do [ "$(cd /opt/zabbix && docker compose ps --status running --services | wc -l)" = 4 ] && exit 0; sleep 10; done; exit 1'
vmchk "в журнале предыдущей загрузки есть записи (journal постоянный)" '[ "$(journalctl --list-boots | wc -l)" -ge 2 ]'
failed=$(vm "systemctl --failed --no-legend --plain | awk '{print \$1}'" || true)
bad=$(echo "$failed" | grep -Ev '^(hv[-_a-z]*|hyperv[-_a-z]*)\.service$|^$' || true)
[ -z "$bad" ] || fail "после перезагрузки упавшие юниты: $bad"
tok=$(login "$NEWPW"); [ -n "$tok" ] || fail "после перезагрузки вход Admin с новым паролем не работает"
echo "  ok: данные (новый пароль Admin) сохранились после перезагрузки"

# поставляемый диск не менялся
[ "$(sha256sum "$BASE" | cut -d' ' -f1)" = "$BASE_SUM" ] || fail "базовый диск изменился"
kill "$(cat qemu.pid)"; sleep 5; cp serial.log "serial-$MODE.log"
echo "== тест $MODE пройден"
