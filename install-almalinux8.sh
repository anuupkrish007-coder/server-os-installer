#!/usr/bin/env bash
set -eo pipefail

echo "===================================================="
echo "  AlmaLinux 8 Native Installer (via Rocky Rescue)"
echo "===================================================="

# Ensure required deployment tools exist on Rocky host
dnf install -y parted e2fsprogs iproute curl

# Active network auto-detection
ACTIVE_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || ip route | grep default | grep -oP 'dev \K\S+' | head -n1)
MAC_ADDR=$(cat /sys/class/net/${ACTIVE_IFACE}/address 2>/dev/null || true)

echo "--> Detected Active Interface: $ACTIVE_IFACE ($MAC_ADDR)"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

# Inputs
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

# Convert netmask to CIDR prefix
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

# 1. Unmount existing partitions
echo "--> Unmounting existing mounts..."
fuser -km /mnt/target 2>/dev/null || true
umount -R -f -l /mnt/target 2>/dev/null || true

# 2. Partition disk (MBR for BIOS boot)
echo "--> Partitioning $OS_DISK with MBR layout..."
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

# 3. Format filesystem
echo "--> Formatting $ROOT_PART (ext4 compatible)..."
mkfs.ext4 -F -O "^metadata_csum_seed,^orphan_file" "$ROOT_PART"

mkdir -p /mnt/target
mount "$ROOT_PART" /mnt/target

# 4. Bootstrap AlmaLinux 8 release packages & repository
echo "--> Bootstrapping AlmaLinux 8 release repositories..."
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

# 5. Native DNF Installroot
echo "--> Installing AlmaLinux 8 Core Packages via native DNF..."
dnf -y --config=/tmp/almalinux8-bootstrap.repo \
       --installroot=/mnt/target \
       --releasever=8 \
       --setopt=install_weak_deps=False \
       install almalinux-release basesystem bash coreutils dnf \
               kernel grub2-pc grub2-tools openssh-server NetworkManager iproute passwd

# 6. Mount pseudo-filesystems for chroot
echo "--> Binding virtual filesystems..."
for dir in /dev /dev/pts /proc /sys /run; do
    mount --bind "$dir" "/mnt/target$dir"
done

# 7. DNS & Hostname
rm -f /mnt/target/etc/resolv.conf
cat <<RESOLV > /mnt/target/etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV

echo "$HOSTNAME" > /mnt/target/etc/hostname

# 8. Network configuration (ifcfg)
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

# 9. Persistent fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
cat <<FSTAB > /mnt/target/etc/fstab
UUID=${ROOT_UUID}  /  ext4  defaults,noatime  0 1
FSTAB

# 10. Chroot: GRUB, SSH, and Services
echo "--> Configuring bootloader and services in chroot..."
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

# 11. Sync and clean unmount
echo "--> Unmounting target..."
sync
umount -R /mnt/target 2>/dev/null || true

echo "===================================================="
echo "  AlmaLinux 8 Installation Complete!"
echo "  Run 'reboot' to boot into AlmaLinux 8."
echo "===================================================="
