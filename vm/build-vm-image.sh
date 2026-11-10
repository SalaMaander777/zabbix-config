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

echo ">> увеличение диска до $DISK_SIZE (raw, sparse)"
truncate -s "$DISK_SIZE" "$WORK/disk.raw"
ROOTDEV=$(awk '$1 ~ /^\/dev\/sda/ && $2=="filesystem" && $3=="ext4"{print $1}' "$WORK/layout.txt" | head -n1)
: "${ROOTDEV:=/dev/sda1}"
echo "корневой раздел: $ROOTDEV"
sudo -E virt-resize --expand "$ROOTDEV" "$WORK/base.qcow2" "$WORK/disk.raw"
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

echo ">> кастомизация (chroot на loop-устройстве)"
MNT=$WORK/mnt
LOOP=$(sudo losetup -fP --show "$WORK/disk.raw")
cleanup() {
  for d in dev/pts dev proc sys; do sudo umount -l "$MNT/$d" 2>/dev/null || true; done
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT
sudo partprobe "$LOOP" || true
sleep 2
ROOTPART=$(lsblk -lnpo NAME,FSTYPE "$LOOP" | awk '$2=="ext4"{print $1}' | head -n1)
echo "root: $ROOTPART"
mkdir -p "$MNT"
sudo mount "$ROOTPART" "$MNT"
sudo mount --bind /dev "$MNT/dev"; sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"; sudo mount -t sysfs sys "$MNT/sys"
df -h "$MNT"
sudo cp -a "$WORK/stage/etc/apt/." "$MNT/etc/apt/"
sudo cp -a "$ROOT/vm/overlay/." "$MNT/"
sudo mkdir -p "$MNT/opt"
sudo cp -a "$WORK/stage/opt/zabbix" "$MNT/opt/"
sudo cp "$IMAGES" "$MNT/opt/zabbix/images.tar"
sudo cp "$ROOT/vm/customize-chroot.sh" "$MNT/tmp/customize.sh"
sudo rm -f "$MNT/etc/resolv.conf"
sudo cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
sudo chroot "$MNT" /bin/bash /tmp/customize.sh 2>&1 | tee "$WORK/customize.log"
sudo rm -f "$MNT/etc/resolv.conf"
sudo ln -s /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

echo ">> проверка содержимого образа"
ls -l "$MNT/opt/zabbix" "$MNT/opt/zabbix/map/data" | tee "$WORK/ls-opt.txt"
test -f "$MNT/opt/zabbix/images.tar"
test -f "$MNT/etc/systemd/system/zabbix-firstboot.service"
test -L "$MNT/etc/systemd/system/multi-user.target.wants/zabbix-firstboot.service"
sync
cleanup
trap - EXIT

echo ">> конвертация в VHDX"
sudo chown "$(id -u):$(id -g)" "$WORK/disk.raw"
mv "$WORK/disk.raw" "$WORK/final.raw"   # для теста (не поставляется)
qemu-img convert -p -f raw -O vhdx -o subformat=dynamic "$WORK/final.raw" "$OUT/$NAME.vhdx"
ls -l "$OUT"

( cd "$OUT" && zip -1 "$NAME.zip" "$NAME.vhdx" && rm "$NAME.vhdx" )
cp docs/HYPERV-VM.md "$OUT/" 2>/dev/null || true
cp scripts/precheck.ps1 scripts/hyperv-install.ps1 scripts/hyperv-create-vm.ps1 "$OUT/"
cat > "$OUT/BUILD-INFO.txt" <<EOT
Образ: $NAME.vhdx (в zip). Основа: debian-12-nocloud-amd64.qcow2 (cloud.debian.org). Диск 40 ГБ (динамический).
Поколение ВМ Hyper-V: $( [ "$EFI" = yes ] && echo "2 (UEFI, EFI-раздел есть, шаблон Secure Boot MicrosoftUEFICertificateAuthority)" || echo "1" )
Сборка: $(date -u +%F)
EOT
echo "$EFI" > "$WORK/efi"
( cd "$OUT" && sha256sum ./* > SHA256SUMS && cat SHA256SUMS )
echo "Готово: $OUT"
