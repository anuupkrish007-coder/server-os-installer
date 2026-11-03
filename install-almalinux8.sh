#!/usr/bin/env bash
set -eo pipefail

echo "===================================================="
echo "  Universal AlmaLinux 8 Rescue Installer"
echo "===================================================="

# Host tool verification (works on Debian/Grml, Ubuntu, CentOS, RHEL)
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq parted curl tar xz-utils e2fsprogs iproute2
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y parted curl tar xz e2fsprogs iproute
elif command -v yum >/dev/null 2>&1; then
    yum install -y parted curl tar xz e2fsprogs iproute
fi

DETECTED_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || ip route | grep default | grep -oP 'dev \K\S+' | head -n1)
MAC_ADDR=$(cat /sys/class/net/${DETECTED_IFACE}/address 2>/dev/null || true)

echo "--> Detected Active Interface: $DETECTED_IFACE ($MAC_ADDR)"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

read -rp "Enter target disk name (e.g., sda, sdb, nvme0n1): " OS_INPUT
OS_INPUT=$(echo "$OS_INPUT" | sed 's|^/dev/||')
OS_DISK="/dev/${OS_INPUT}"

read -rp "Enter Hostname [almacenter]: " HOSTNAME
HOSTNAME=${HOSTNAME:-almacenter}

read -rp "Enter Server Public IP: " IP_ADDR
read -rp "Enter Subnet Netmask (e.g., 255.255.255.192): " NETMASK
read -rp "Enter Default Gateway IP: " GATEWAY
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
if [[ ! "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Aborted."
    exit 1
fi

echo "--> Unmounting existing target mounts..."
fuser -km /mnt/target 2>/dev/null || true
umount -R -f -l /mnt/target 2>/dev/null || true

echo "--> Wiping partition table on $OS_DISK..."
dd if=/dev/zero of="$OS_DISK" bs=1M count=20 status=none

echo "--> Partitioning $OS_DISK with MBR layout..."
parted -s "$OS_DISK" mklabel msdos
parted -s "$OS_DISK" mkpart primary ext4 1MiB 100%
parted -s "$OS_DISK" set 1 boot on
partprobe "$OS_DISK" && sleep 2

if [[ "$OS_INPUT" =~ [0-9]$ ]]; then
    ROOT_PART="${OS_DISK}p1"
else
    ROOT_PART="${OS_DISK}1"
fi

echo "--> Formatting Root Partition ($ROOT_PART)..."
mkfs.ext4 -F -O "^metadata_csum_seed,^orphan_file" "$ROOT_PART"

mkdir -p /mnt/target
mount "$ROOT_PART" /mnt/target

echo "--> Extracting AlmaLinux 8 RootFS..."
curl -sSL "https://raw.githubusercontent.com/almalinux/docker-images/refs/heads/almalinux-8/almalinux-8-default.tar.xz" | tar -xJ -C /mnt/target

for dir in /dev /dev/pts /proc /sys /run; do
    mount --bind "$dir" "/mnt/target$dir"
done

rm -f /mnt/target/etc/resolv.conf
cat <<RESOLV > /mnt/target/etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV

echo "$HOSTNAME" > /mnt/target/etc/hostname

mkdir -p /mnt/target/etc/sysconfig/network-scripts
cat <<NETCFG > /mnt/target/etc/sysconfig/network-scripts/ifcfg-${DETECTED_IFACE}
DEVICE=${DETECTED_IFACE}
BOOTPROTO=none
ONBOOT=yes
IPADDR=${IP_ADDR}
PREFIX=${CIDR_PREFIX}
GATEWAY=${GATEWAY}
DNS1=1.1.1.1
DNS2=8.8.8.8
NETCFG

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
cat <<FSTAB > /mnt/target/etc/fstab
UUID=${ROOT_UUID}  /  ext4  defaults,noatime  0 1
FSTAB

echo "--> Running configuration in chroot..."
chroot /mnt/target /bin/bash -s <<CHROOT_EOF
set -e
dnf clean all
dnf install -y kernel grub2-pc grub2-tools openssh-server NetworkManager iproute

mkdir -p /boot/grub2
grub2-install --target=i386-pc "$OS_DISK"
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
echo "  AlmaLinux 8 Installation Complete."
echo "  Run 'reboot' to boot into the new OS."
echo "===================================================="
