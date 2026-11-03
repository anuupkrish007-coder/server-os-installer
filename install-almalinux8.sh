#!/usr/bin/env bash
set -eo pipefail

echo "===================================================="
echo "  Universal AlmaLinux 8 Installer (Rescue Mode)"
echo "===================================================="

# 1. Install prerequisites on host
if command -v dnf >/dev/null 2>&1; then
    dnf install -y parted e2fsprogs iproute curl
elif command -v yum >/dev/null 2>&1; then
    yum install -y parted e2fsprogs iproute curl
fi

ACTIVE_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || ip route | grep default | grep -oP 'dev \K\S+' | head -n1)
MAC_ADDR=$(cat /sys/class/net/${ACTIVE_IFACE}/address 2>/dev/null || true)

echo "--> Detected Network Interface: $ACTIVE_IFACE ($MAC_ADDR)"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

read -rp "Enter target disk name [default: sda]: " OS_INPUT
OS_INPUT=${OS_INPUT:-sda}
OS_INPUT=$(echo "$OS_INPUT" | sed 's|^/dev/||')
OS_DISK="/dev/${OS_INPUT}"

read -rp "Enter Hostname [hosted-by.Eqservers.com]: " HOSTNAME
HOSTNAME=${HOSTNAME:-hosted-by.Eqservers.com}

read -rp "Enter Server Public IP [83.149.120.156]: " IP_ADDR
IP_ADDR=${IP_ADDR:-83.149.120.156}

read -rp "Enter Subnet Netmask [255.255.255.192]: " NETMASK
NETMASK=${NETMASK:-255.255.255.192}

read -rp "Enter Default Gateway IP [83.149.120.190]: " GATEWAY
GATEWAY=${GATEWAY:-83.149.120.190}

read -rsp "Enter Root Password for New OS: " ROOT_PASS
echo ""

cdr() {
    local x=${1##*255.}
    set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
    x=${1%%$3*}
    echo $(( $2 + (${#x}/4) ))
}
CIDR_PREFIX=$(cdr "$NETMASK")

read -rp "WARNING: ALL DATA ON $OS_DISK WILL BE ERASED! Proceed? (type YES): " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

echo "--> Cleaning up target mounts..."
fuser -km /mnt/target 2>/dev/null || true
umount -R -f -l /mnt/target 2>/dev/null || true

echo "--> Partitioning $OS_DISK (MBR layout)..."
dd if=/dev/zero of="$OS_DISK" bs=1M count=20 status=none
parted -s "$OS_DISK" mklabel msdos
parted -s "$OS_DISK" mkpart primary ext4 1MiB 100%
parted -s "$OS_DISK" set 1 boot on
partprobe "$OS_DISK" && sleep 2

if [[ "$OS_INPUT" =~ [0-9]$ ]]; then
    ROOT_PART="${OS_DISK}p1"
else
    ROOT_PART="${OS_DISK}1"
fi

echo "--> Formatting $ROOT_PART..."
mkfs.ext4 -F "$ROOT_PART"

mkdir -p /mnt/target
mount "$ROOT_PART" /mnt/target

echo "--> Configuring bootstrap repositories..."
mkdir -p /mnt/target/etc/yum.repos.d
cat << 'REPO_EOF' > /tmp/almalinux8-bootstrap.repo
[baseos]
name=AlmaLinux 8 - BaseOS
baseurl=https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/
enabled=1
gpgcheck=0

[appstream]
name=AlmaLinux 8 - AppStream
baseurl=https://repo.almalinux.org/almalinux/8/AppStream/x86_64/os/
enabled=1
gpgcheck=0
REPO_EOF

echo "--> Bootstrapping base packages..."
dnf -y --config=/tmp/almalinux8-bootstrap.repo \
       --installroot=/mnt/target \
       --releasever=8 \
       --setopt=install_weak_deps=False \
       install almalinux-release basesystem bash coreutils dnf \
               kernel grub2-pc grub2-tools openssh-server NetworkManager iproute \
               passwd hostname

# Pin releasever inside the installation to avoid future mirror issues
mkdir -p /mnt/target/etc/dnf/vars
echo "8" > /mnt/target/etc/dnf/vars/releasever

# Copy default profile files so bash-4.4# prompt doesn't occur
cp /mnt/target/etc/skel/.bash* /mnt/target/root/ 2>/dev/null || true

echo "--> Binding virtual filesystems..."
for dir in /dev /dev/pts /proc /sys /run; do
    mount --bind "$dir" "/mnt/target$dir"
done

# DNS & Hostname
rm -f /mnt/target/etc/resolv.conf
cat <<RESOLV > /mnt/target/etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV

echo "$HOSTNAME" > /mnt/target/etc/hostname

# Static Network Config
mkdir -p /mnt/target/etc/sysconfig/network-scripts
cat <<NETCFG > /mnt/target/etc/sysconfig/network-scripts/ifcfg-${ACTIVE_IFACE}
DEVICE=${ACTIVE_IFACE}
BOOTPROTO=none
ONBOOT=yes
IPADDR=${IP_ADDR}
PREFIX=${CIDR_PREFIX}
GATEWAY=${GATEWAY}
DNS1=1.1.1.1
DNS2=8.8.8.8
NETCFG

# Hosts entry
cat <<HOSTS > /mnt/target/etc/hosts
127.0.0.1   localhost localhost.localdomain
::1         localhost localhost.localdomain
${IP_ADDR}  ${HOSTNAME} ${HOSTNAME%%.*}
HOSTS

# Persistent Fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
cat <<FSTAB > /mnt/target/etc/fstab
UUID=${ROOT_UUID}  /  ext4  defaults,noatime  0 1
FSTAB

echo "--> Finalizing bootloader and credentials in chroot..."
chroot /mnt/target /bin/bash -s <<CHROOT_EOF
set -e

mkdir -p /boot/grub2
echo "(hd0) $OS_DISK" > /boot/grub2/device.map
grub2-install --target=i386-pc --recheck "$OS_DISK"
grub2-mkconfig -o /boot/grub2/grub.cfg

sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
echo "root:${ROOT_PASS}" | chpasswd

systemctl enable NetworkManager
systemctl enable sshd
CHROOT_EOF

sync
umount -R /mnt/target 2>/dev/null || true

echo "===================================================="
echo "  AlmaLinux 8 Installation Complete!"
echo "  Run 'reboot' to boot into the new OS."
echo "===================================================="
