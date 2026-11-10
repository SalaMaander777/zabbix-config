#!/usr/bin/env bash
# Выполняется ВНУТРИ chroot образа (из build-vm-image.sh). Сеть - хостовая.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# не стартовать службы внутри chroot
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get install -y ca-certificates curl gnupg python3 chrony hyperv-daemons openssh-server sudo tzdata less nano rsync iproute2
# Облачное ядро Debian (linux-image-cloud) без драйверов AHCI и e1000, нужных VirtualBox:
# ставим обычное ядро (в нём есть ahci, e1000, virtio, hv_*) и убираем облачное.
apt-get install -y linux-image-amd64
apt-get purge -y 'linux-image-*-cloud-amd64' linux-image-cloud-amd64 || true
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

chmod +x /usr/local/sbin/zbx-* /opt/zabbix/scripts/*.sh
rm -f /etc/netplan/*.yaml /etc/network/interfaces.d/* 2>/dev/null || true

for m in hv_vmbus hv_storvsc hv_netvsc hv_utils hv_balloon hyperv_keyboard hid_hyperv; do
  grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
done
# в initramfs: диск и сеть для Hyper-V (hv_*), VirtualBox (ahci, e1000), QEMU (virtio)
for m in ahci e1000 virtio_blk virtio_net virtio_pci; do
  grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
done
update-initramfs -u -k all
update-grub
grep -E '^\s*linux\s' /boot/grub/grub.cfg | head
if grep -E '^\s*linux\s' /boot/grub/grub.cfg | grep -q cloud; then echo 'в grub.cfg осталось облачное ядро'; exit 1; fi
ls /boot/vmlinuz-* /boot/initrd.img-*

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime; echo Europe/Moscow > /etc/timezone
echo zabbix-vm > /etc/hostname
sed -i '/^127.0.1.1/d' /etc/hosts; echo '127.0.1.1 zabbix-vm' >> /etc/hosts

systemctl enable docker containerd ssh chrony systemd-networkd systemd-resolved \
  zabbix-firstboot.service zabbix-stack.service zabbix-backup.timer
systemctl disable systemd-timesyncd 2>/dev/null || true
systemctl mask cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true

id zbxadmin >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,docker zbxadmin
echo 'zbxadmin:zbxadmin' | chpasswd
chage -d 0 zbxadmin
passwd -l root
rm -f /etc/ssh/ssh_host_*

dpkg -l | grep -E 'linux-image|shim|grub-efi|docker-ce |chrony|hyperv' | awk '{print $2, $3}'
ls /lib/modules/*/kernel/drivers/hv /lib/modules/*/kernel/drivers/net/hyperv 2>&1 | head -20 || true

rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/*.log /var/log/journal/* /root/.bash_history /tmp/customize.sh
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
