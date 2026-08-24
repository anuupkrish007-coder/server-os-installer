#!/usr/bin/env bash
set -eo pipefail

echo "===================================================="
echo "  Universal AlmaLinux 8 Rescue Installer"
echo "===================================================="

# --------------------------------------------------
# 1. Automatic Network Interface Detection
# --------------------------------------------------
echo "--> Auto-detecting active network interface..."
DETECTED_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || true)
if [ -z "$DETECTED_IFACE" ]; then
    DETECTED_IFACE=$(ip route | grep default | grep -oP 'dev \K\S+' | head -n1)
fi

echo "--> Detected Active Interface: ${DETECTED_IFACE}"

# Ensure essential partitioning tools exist
for tool in parted gdisk e2fsprogs dnf; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "--> Installing $tool..."
        dnf install -y $tool || true
    fi
done

# --------------------------------------------------
# 2. Disk Selection & Network Prompts
# --------------------------------------------------
echo ""
echo "--> Available Disks:"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

echo ""
echo "--> Current Network Routes:"
ip route

echo ""
read -rp "Enter target disk name (e.g., sda, sdb, nvme0n1): " TARGET_DISK_INPUT

TARGET_DISK_INPUT=$(echo "$TARGET_DISK_INPUT" | sed 's|^/dev/||')
TARGET_DISK="/dev/${TARGET_DISK_INPUT}"

if [ ! -b "$TARGET_DISK" ]; then
    echo "ERROR: Device $TARGET_DISK does not exist!"
    exit 1
fi

if [[ "$TARGET_DISK_INPUT" =~ [0-9]$ ]]; then
    PART_PREFIX="${TARGET_DISK}p"
else
    PART_PREFIX="${TARGET_DISK}"
fi

DISK_SIZE_BYTES=$(blockdev --getsize64 "$TARGET_DISK")
TWO_TB_BYTES=2199023255552

read -rp "Enter Hostname [almacenter]: " HOSTNAME
HOSTNAME=${HOSTNAME:-almacenter}

read -rp "Enter Server Public IP: " IP_ADDR
read -rp "Enter Subnet Netmask (e.g., 255.255.255.192): " NETMASK
read -rp "Enter Default Gateway IP: " GATEWAY
read -rsp "Enter Root Password for New OS: " ROOT_PASS
echo ""

MAC_ADDR=$(cat /sys/class/net/${DETECTED_IFACE}/address 2>/dev/null || true)

echo ""
echo "===================================================="
echo " Summary of Installation Settings:"
echo " OS:              AlmaLinux 8"
echo " Target Disk:     $TARGET_DISK"
echo " Interface:       $DETECTED_IFACE ($MAC_ADDR)"
echo " Hostname:        $HOSTNAME"
echo " IP Address:      $IP_ADDR"
echo " Netmask:         $NETMASK"
echo " Gateway:         $GATEWAY"
echo "===================================================="
read -rp "WARNING: ALL DATA ON $TARGET_DISK WILL BE ERASED! Proceed? (type YES): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# --------------------------------------------------
# 3. Disk Wipe and Partitioning (GPT vs MBR)
# --------------------------------------------------
echo "--> Unmounting existing target mounts..."
umount -R /mnt/target 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo "--> Wiping partition table on $TARGET_DISK..."
dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 status=none
sync

if [ "$DISK_SIZE_BYTES" -gt "$TWO_TB_BYTES" ]; then
    echo "--> Disk >2TB detected ($DISK_SIZE_BYTES bytes). Creating GPT Partition Scheme..."
    parted -s "$TARGET_DISK" mklabel gpt
    parted -s "$TARGET_DISK" mkpart primary 1MiB 3MiB
    parted -s "$TARGET_DISK" set 1 bios_grub on
    parted -s "$TARGET_DISK" mkpart primary xfs 3MiB 100%
    
    BOOT_PART="${PART_PREFIX}1"
    ROOT_PART="${PART_PREFIX}2"
else
    echo "--> Disk <=2TB detected ($DISK_SIZE_BYTES bytes). Creating MBR Partition Scheme..."
    parted -s "$TARGET_DISK" mklabel msdos
    parted -s "$TARGET_DISK" mkpart primary xfs 1MiB 100%
    parted -s "$TARGET_DISK" set 1 boot on
    
    ROOT_PART="${PART_PREFIX}1"
fi

partprobe "$TARGET_DISK"
sleep 2

echo "--> Formatting Root Partition ($ROOT_PART)..."
mkfs.xfs -f "$ROOT_PART"

echo "--> Mounting Target File System..."
mkdir -p /mnt/target
mount "$ROOT_PART" /mnt/target

# --------------------------------------------------
# 4. Bootstrap AlmaLinux 8 Base Packages via DNF
# --------------------------------------------------
echo "--> Creating DNF Repo Config for AlmaLinux 8..."
mkdir -p /tmp/almaconf
cat <<EOF > /tmp/almaconf/almalinux.repo
[baseos]
name=AlmaLinux 8 - BaseOS
baseurl=https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/
gpgcheck=0
enabled=1

[appstream]
name=AlmaLinux 8 - AppStream
baseurl=https://repo.almalinux.org/almalinux/8/AppStream/x86_64/os/
gpgcheck=0
enabled=1
EOF

echo "--> Installing AlmaLinux 8 Core Packages..."
dnf --installroot=/mnt/target -c /tmp/almaconf/almalinux.repo \
    --releasever=8 --setopt=install_weak_deps=False -y \
    groupinstall "Minimal Install"

dnf --installroot=/mnt/target -c /tmp/almaconf/almalinux.repo \
    --releasever=8 -y install \
    kernel grub2-pc grub2-tools openssh-server NetworkManager iproute dhcp-client

rm -rf /tmp/almaconf

# --------------------------------------------------
# 5. Network & System Configuration
# --------------------------------------------------
echo "--> Mounting Virtual Filesystems for Chroot..."
for dir in /dev /dev/pts /proc /sys /run; do
    mount --bind "$dir" "/mnt/target$dir"
done

echo "$HOSTNAME" > /mnt/target/etc/hostname

cat <<EOF > /mnt/target/etc/hosts
127.0.0.1   localhost localhost.localdomain
$IP_ADDR   $HOSTNAME
EOF

# Lock interface naming via udev rule
if [ -n "$MAC_ADDR" ]; then
    mkdir -p /mnt/target/etc/udev/rules.d
    cat <<EOF > /mnt/target/etc/udev/rules.d/70-persistent-net.rules
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="${MAC_ADDR}", NAME="${DETECTED_IFACE}"
EOF
fi

# Create legacy ifcfg script for network compatibility
mkdir -p /mnt/target/etc/sysconfig/network-scripts
cat <<EOF > /mnt/target/etc/sysconfig/network-scripts/ifcfg-${DETECTED_IFACE}
TYPE=Ethernet
PROXY_METHOD=none
BROWSER_ONLY=no
BOOTPROTO=none
DEFROUTE=yes
IPV4_FAILURE_FATAL=no
IPV6INIT=no
NAME=${DETECTED_IFACE}
DEVICE=${DETECTED_IFACE}
ONBOOT=yes
IPADDR=${IP_ADDR}
NETMASK=${NETMASK}
GATEWAY=${GATEWAY}
DNS1=1.1.1.1
DNS2=8.8.8.8
EOF

# Generate fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
cat <<EOF > /mnt/target/etc/fstab
UUID=${ROOT_UUID}  /  xfs  defaults  0  0
EOF

# --------------------------------------------------
# 6. Chroot Configuration (GRUB, Password, SSH & SELinux)
# --------------------------------------------------
echo "--> Executing Chroot Setup..."
chroot /mnt/target /bin/bash -s <<EOF
set -e

# Disable SELinux enforcement to prevent SSH drops on bootstrapped setups
if [ -f /etc/selinux/config ]; then
    sed -i 's/SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
fi
touch /.autorelabel

# Enable Root SSH Login
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# Set Root Password using chpasswd
echo "root:${ROOT_PASS}" | chpasswd

# Generate SSH Host Keys and fix permissions
ssh-keygen -A
chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true

# Enable NetworkManager and SSH
systemctl enable NetworkManager
systemctl enable sshd

# Install & Configure GRUB2
grub2-install "$TARGET_DISK"
grub2-mkconfig -o /boot/grub2/grub.cfg
EOF

# --------------------------------------------------
# 7. Clean Up
# --------------------------------------------------
echo "--> Cleaning up mounts..."
umount -R /mnt/target 2>/dev/null || true

echo "===================================================="
echo " AlmaLinux 8 Installation Complete!"
echo " Run '# reboot' to start your new OS."
echo "===================================================="
