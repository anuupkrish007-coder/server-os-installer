#!/usr/bin/env bash
# EqServers Runbook: Ubuntu 18.04.6 LTS Automated Rescue Mode Installer
set -euo pipefail

echo "===================================================="
echo " Ubuntu 18.04.6 LTS Rescue Mode Installer"
echo "===================================================="

# --- 1. System Discovery ---
echo "--> Checking Environment..."
[ -d /sys/firmware/efi ] && BOOT_MODE="UEFI" || BOOT_MODE="Legacy BIOS"
echo "Boot Mode: $BOOT_MODE"

echo -e "\n--> Available Disks:"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

echo -e "\n--> Current Network Routes (Identify your Gateway):"
ip route

echo "===================================================="
# --- 2. Interactive Variable Inputs ---
read -rp "Enter TARGET DISK (e.g. sda, nvme0n1): " TARGET_NAME
TARGET_DISK="/dev/${TARGET_NAME}"

if [[ ! -b "$TARGET_DISK" ]]; then
    echo "Error: Device $TARGET_DISK does not exist!"
    exit 1
fi

read -rp "Enter Server Hostname: " HOSTNAME_VAR
read -rp "Enter Server Static IP: " SERVER_IP
read -rp "Enter Netmask (e.g., 255.255.255.0): " NETMASK_VAR
read -rp "Enter Gateway IP (from ip route above): " GATEWAY_IP
read -rsp "Enter Root Password for new system: " ROOT_PASS
echo ""

echo "===================================================="
echo "WARNING: DESTROYING ALL DATA ON $TARGET_DISK"
read -rp "Type 'YES' to proceed with installation: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# --- 3. Disk Partitioning & Formatting ---
echo "--> Partitioning and formatting $TARGET_DISK..."
wipefs -a "$TARGET_DISK"
parted -s "$TARGET_DISK" mklabel msdos
parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%
parted -s "$TARGET_DISK" set 1 boot on
partprobe "$TARGET_DISK" || true
udevadm settle || sleep 2

PART_DEV="${TARGET_DISK}1"
[[ "$TARGET_NAME" == nvme* ]] && PART_DEV="${TARGET_DISK}p1"

mkfs.ext4 -F -L rootfs "$PART_DEV"
mkdir -p /mnt/target
mount "$PART_DEV" /mnt/target

# --- 4. Install Debootstrap & Bootstrap OS ---
if ! command -v debootstrap &>/dev/null; then
    echo "--> Installing debootstrap host package..."
    dnf install -y epel-release || true
    dnf install -y debootstrap || apt-get update && apt-get install -y debootstrap
fi

echo "--> Running debootstrap (Ubuntu Bionic)..."
debootstrap --arch=amd64 bionic /mnt/target http://archive.ubuntu.com/ubuntu/

# --- 5. Mount Virtual Filesystems & DNS ---
echo "--> Preparing Chroot Environment..."
for fs in dev dev/pts proc sys; do
  mount --bind /$fs /mnt/target/$fs
done

cp /etc/resolv.conf /mnt/target/etc/resolv.conf

# --- 6. In-Chroot Configuration Script ---
echo "--> Running setup inside chroot..."
chroot /mnt/target /bin/bash -c "
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo '$HOSTNAME_VAR' > /etc/hostname

cat > /etc/apt/sources.list <<'EOF'
deb http://archive.ubuntu.com/ubuntu/ bionic main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ bionic-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ bionic-security main restricted universe multiverse
EOF

apt-get update
apt-get install -y linux-image-generic grub-pc openssh-server sudo vim net-tools iproute2 ifupdown

echo 'root:$ROOT_PASS' | chpasswd

# Determine default network interface name
IFACE=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v 'lo' | head -n1)
[ -z \"\$IFACE\" ] && IFACE=\"eno1\"

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto \$IFACE
iface \$IFACE inet static
    address $SERVER_IP
    netmask $NETMASK_VAR
    gateway $GATEWAY_IP
    dns-nameservers 8.8.8.8 1.1.1.1
EOF

echo '127.0.0.1 localhost' > /etc/hosts
echo \"127.0.1.1 $HOSTNAME_VAR\" >> /etc/hosts

ROOT_UUID=\$(blkid -s UUID -o value '$PART_DEV')
echo \"UUID=\$ROOT_UUID / ext4 errors=remount-ro 0 1\" > /etc/fstab

grub-install --target=i386-pc '$TARGET_DISK'
update-grub

systemctl enable ssh
systemctl enable networking
"

# --- 7. Validation & Cleanup ---
echo "===================================================="
echo "--> Running Pre-Reboot Validation Checks..."

if [ -f /mnt/target/boot/grub/i386-pc/core.img ]; then
    echo "[PASS] GRUB core.img present."
else
    echo "[FAIL] GRUB core.img missing!"
fi

if ls /mnt/target/boot/vmlinuz-* &>/dev/null; then
    echo "[PASS] Kernel image present."
else
    echo "[FAIL] Kernel image missing!"
fi

if [ -s /mnt/target/etc/fstab ]; then
    echo "[PASS] /etc/fstab populated."
else
    echo "[FAIL] /etc/fstab is empty!"
fi

echo "--> Unmounting target filesystems..."
for fs in dev/pts dev proc sys; do
  umount /mnt/target/$fs || true
done
umount /mnt/target || true
sync

echo "===================================================="
echo "Installation completed! You can now safely run: reboot"
echo "===================================================="
