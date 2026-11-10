#!/usr/bin/env bash
# Сборка ВМ Hyper-V (Debian 12 nocloud + Docker + стек Zabbix). Запуск: ubuntu-latest, sudo доступен.
# Вход: dist/zabbix-offline-*/images.tar (scripts/build-offline-bundle.sh). Выход: vm/out/
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=$ROOT/vm/work
OUT=$ROOT/vm/out
BASE_URL=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2
DISK_SIZE=40G
NAME=zabbix-vm-debian12

# shellcheck disable=SC2012
IMAGES=$(ls -1 dist/zabbix-offline-*/images.tar | tail -n 1)
[ -f "$IMAGES" ] || { echo "нет images.tar"; exit 1; }

sudo apt-get update -qq
sudo apt-get install -y libguestfs-tools qemu-utils zip gnupg curl >/dev/null
sudo chmod 0644 /boot/vmlinuz* || true
export LIBGUESTFS_BACKEND=direct

sudo rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
echo ">> скачивание базового образа"
curl -fL --retry 3 -o "$WORK/base.qcow2" "$BASE_URL"
qemu-img info "$WORK/base.qcow2"

echo ">> раскладка разделов базового образа"
sudo -E virt-filesystems --long -h --all -a "$WORK/base.qcow2" | tee "$WORK/layout.txt"
# Gen 2 (UEFI) возможен только при наличии EFI-раздела
EFI=no; grep -qi 'vfat' "$WORK/layout.txt" && EFI=yes
echo "EFI=$EFI"

echo ">> увеличение диска до $DISK_SIZE"
qemu-img create -f qcow2 "$WORK/disk.qcow2" "$DISK_SIZE"
ROOTDEV=$(awk '$1 ~ /^\/dev\/sda/ && $2=="filesystem" && $3=="ext4"{print $1}' "$WORK/layout.txt" | head -n1)
: "${ROOTDEV:=/dev/sda1}"
echo "корневой раздел: $ROOTDEV"
sudo -E virt-resize --expand "$ROOTDEV" "$WORK/base.qcow2" "$WORK/disk.qcow2"
rm -f "$WORK/base.qcow2"

echo ">> ключ репозитория Docker и стек"
mkdir -p "$WORK/stage/etc/apt/keyrings" "$WORK/stage/etc/apt/sources.list.d" "$WORK/stage/opt/zabbix"
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o "$WORK/stage/etc/apt/keyrings/docker.gpg"
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable' \
  > "$WORK/stage/etc/apt/sources.list.d/docker.list"
cp -R docker-compose.yml docker-compose.map.yml .env.example server zabbix templates scripts docs "$WORK/stage/opt/zabbix/"
# карта: код и moscow.pmtiles берём из комплекта (build-offline-bundle.sh)
cp -R "$(dirname "$IMAGES")/map" "$WORK/stage/opt/zabbix/map"
ls -lh "$WORK/stage/opt/zabbix/map/data"
mkdir -p "$WORK/stage/opt/zabbix/backups"; chmod 777 "$WORK/stage/opt/zabbix/backups"
chmod +x "$WORK/stage/opt/zabbix/scripts/"*.sh

echo ">> кастомизация (virt-customize)"
sudo -E virt-customize -a "$WORK/disk.qcow2" --memsize 2048 --network \
  --run-command 'rm -f /etc/resolv.conf; printf "nameserver 168.63.129.16\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf' \
  --copy-in "$WORK/stage/etc/apt:/etc" \
  --run-command 'apt-get update' \
  --install ca-certificates,curl,python3,chrony,hyperv-daemons,openssh-server,sudo,tzdata,less,nano,rsync,iproute2 \
  --run-command 'apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin' \
  --copy-in "$ROOT/vm/overlay/etc:/" \
  --copy-in "$ROOT/vm/overlay/usr:/" \
  --copy-in "$WORK/stage/opt/zabbix:/opt" \
  --copy-in "$IMAGES:/opt/zabbix" \
  --run-command 'chmod +x /usr/local/sbin/zbx-* /opt/zabbix/scripts/*.sh' \
  --run-command 'rm -f /etc/netplan/*.yaml /etc/network/interfaces.d/* 2>/dev/null || true' \
  --run-command 'for m in hv_vmbus hv_storvsc hv_netvsc hv_utils hv_balloon hyperv_keyboard hid_hyperv; do grep -qx $m /etc/initramfs-tools/modules || echo $m >> /etc/initramfs-tools/modules; done; update-initramfs -u -k all || true' \
  --run-command 'ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime; echo Europe/Moscow > /etc/timezone' \
  --run-command 'echo zabbix-vm > /etc/hostname; sed -i "/^127.0.1.1/d" /etc/hosts; echo "127.0.1.1 zabbix-vm" >> /etc/hosts' \
  --run-command 'systemctl enable docker containerd ssh chrony systemd-networkd systemd-resolved zabbix-firstboot.service zabbix-stack.service zabbix-backup.timer' \
  --run-command 'systemctl disable systemd-timesyncd 2>/dev/null || true; systemctl mask cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true' \
  --run-command 'useradd -m -s /bin/bash -G sudo,docker zbxadmin' \
  --password zbxadmin:password:zbxadmin \
  --run-command 'chage -d 0 zbxadmin; passwd -l root' \
  --run-command 'rm -f /etc/ssh/ssh_host_*' \
  --run-command 'apt-get clean; rm -rf /var/lib/apt/lists/* /var/log/*.log /var/log/journal/* /root/.bash_history /tmp/* 2>/dev/null || true' \
  --run-command ': > /etc/machine-id; rm -f /var/lib/dbus/machine-id; ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf' \
  --run-command 'dpkg -l | grep -E "linux-image|shim|grub-efi|docker-ce |chrony|hyperv" | awk "{print \$2, \$3}"; ls /boot/efi/EFI/* 2>/dev/null; ls /lib/modules/*/kernel/drivers/hv /lib/modules/*/kernel/drivers/net/hyperv /lib/modules/*/kernel/drivers/scsi/hv_storvsc.ko* 2>&1 | head -20' \
  | tee "$WORK/customize.log"

echo ">> проверка содержимого образа"
sudo -E virt-ls -a "$WORK/disk.qcow2" /opt/zabbix | tee "$WORK/ls-opt.txt"
grep -qx images.tar "$WORK/ls-opt.txt"
sudo -E virt-ls -a "$WORK/disk.qcow2" /etc/systemd/system/ | grep -q zabbix-firstboot.service

echo ">> конвертация в VHDX"
sudo chown "$(id -u):$(id -g)" "$WORK/disk.qcow2"
qemu-img convert -p -O vhdx -o subformat=dynamic "$WORK/disk.qcow2" "$OUT/$NAME.vhdx"
ls -l "$OUT"
mv "$WORK/disk.qcow2" "$WORK/final.qcow2"   # для теста (не поставляется)

( cd "$OUT" && zip -1 "$NAME.zip" "$NAME.vhdx" && rm "$NAME.vhdx" )
cp docs/HYPERV-VM.md "$OUT/" 2>/dev/null || true
cp scripts/hyperv-install.ps1 scripts/hyperv-create-vm.ps1 "$OUT/"
cat > "$OUT/BUILD-INFO.txt" <<EOT
Образ: $NAME.vhdx (в zip). Основа: debian-12-nocloud-amd64.qcow2 (cloud.debian.org). Диск 40 ГБ (динамический).
Поколение ВМ Hyper-V: $( [ "$EFI" = yes ] && echo "2 (UEFI, EFI-раздел есть, шаблон Secure Boot MicrosoftUEFICertificateAuthority)" || echo "1" )
Сборка: $(date -u +%F)
EOT
echo "$EFI" > "$WORK/efi"
( cd "$OUT" && sha256sum ./* > SHA256SUMS && cat SHA256SUMS )
echo "Готово: $OUT"
