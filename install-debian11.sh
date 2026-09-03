#!/usr/bin/env bash
set -eo pipefail

echo "===================================================="
echo "  Debian 11 (Bullseye) Installer (NVMe OS Only)"
echo "  Target: 1x NVMe (OS) + Pass-Through Raw HDDs"
echo "===================================================="

# --------------------------------------------------
# 1. Environment & Tools Check
# --------------------------------------------------
REQUIRED_TOOLS=("parted" "debootstrap" "mkfs.ext4" "gdisk" "ip")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "--> Installing missing tool: $tool..."
        apt-get update -qq && apt-get install -y -qq parted debootstrap gdisk net-tools iproute2 || true
    fi
done

# Detect Boot Mode (EFI vs BIOS)
IS_EFI=0
if [ -d "/sys/firmware/efi" ]; then
    IS_EFI=1
    echo "--> System booted in UEFI Mode."
else
    echo "--> System booted in Legacy BIOS Mode."
fi

# --------------------------------------------------
# 2. Disk & Network Auto-Detection
# --------------------------------------------------
echo ""
echo "--> Available Disks on System:"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

echo ""
echo "--> Active Network Routes:"
ip route

echo ""
# Auto-detect Network Interface
DETECTED_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || true)
if [ -z "$DETECTED_IFACE" ]; then
    DETECTED_IFACE=$(ip route | grep default | grep -oP 'dev \K\S+' | head -n1)
fi

MAC_ADDR=$(cat /sys/class/net/${DETECTED_IFACE}/address 2>/dev/null || true)

read -rp "Enter OS NVMe Disk Name (e.g., nvme0n1 or sda): " NVME_INPUT
NVME_INPUT=$(echo "$NVME_INPUT" | sed 's|^/dev/||')
NVME_DISK="/dev/${NVME_INPUT}"

if [ ! -b "$NVME_DISK" ]; then
    echo "ERROR: Device $NVME_DISK does not exist!"
    exit 1
fi

echo "Enter HDD names to wipe partition tables for pass-through (separated by space, e.g., sda sdb sdc sdd):"
read -rp "> " -a HDD_INPUTS

HDD_DISKS=()
for hdd in "${HDD_INPUTS[@]}"; do
    clean_hdd=$(echo "$hdd" | sed 's|^/dev/||')
    if [ -b "/dev/${clean_hdd}" ]; then
        HDD_DISKS+=("/dev/${clean_hdd}")
    fi
done

read -rp "Enter Hostname [debian-node]: " HOSTNAME
HOSTNAME=${HOSTNAME:-debian-node}

read -rp "Enter Server Public IP: " IP_ADDR
read -rp "Enter Subnet Netmask (e.g., 255.255.255.192): " NETMASK
read -rp "Enter Default Gateway IP: " GATEWAY
read -rsp "Enter Root Password for Debian 11: " ROOT_PASS
echo ""

echo ""
echo "===================================================="
echo " Summary of Installation Settings:"
echo " OS:              Debian 11 (Bullseye)"
echo " Boot Mode:       $( [ $IS_EFI -eq 1 ] && echo 'UEFI' || echo 'Legacy BIOS' )"
echo " OS NVMe Drive:   $NVME_DISK"
echo " Pass-Through:    ${HDD_DISKS[*]} (Unformatted / Raw)"
echo " Interface:       $DETECTED_IFACE ($MAC_ADDR)"
echo " Hostname:        $HOSTNAME"
echo " IP Address:      $IP_ADDR"
echo " Netmask:         $NETMASK"
echo " Gateway:         $GATEWAY"
echo "===================================================="
read -rp "WARNING: ALL DATA ON OS DISK ($NVME_DISK) AND HDDs WILL BE ERASED! Proceed? (type YES): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# --------------------------------------------------
# 3. Partition NVMe (Hybrid EFI + BIOS GPT Layout)
# --------------------------------------------------
echo "--> Unmounting existing target mounts..."
umount -R /mnt/target 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo "--> Wiping partition headers on NVMe..."
dd if=/dev/zero of="$NVME_DISK" bs=1M count=20 status=none

# Wipe partition signatures on HDDs so customer gets clean raw drives
for hdd in "${HDD_DISKS[@]}"; do
    echo "--> Wiping signature on raw drive $hdd..."
    dd if=/dev/zero of="$hdd" bs=1M count=20 status=none
    parted -s "$hdd" mklabel gpt || true
done
sync

# Partitioning prefix logic (nvme0n1p1 vs sda1)
if [[ "$NVME_INPUT" =~ [0-9]$ ]]; then
    NVME_PART_PREFIX="${NVME_DISK}p"
else
    NVME_PART_PREFIX="${NVME_DISK}"
fi

echo "--> Setting up Hybrid GPT Scheme on $NVME_DISK..."
parted -s "$NVME_DISK" mklabel gpt

# Partition 1: BIOS Boot Partition (2MB for GRUB Legacy)
parted -s "$NVME_DISK" mkpart primary 1MiB 3MiB
parted -s "$NVME_DISK" set 1 bios_grub on

# Partition 2: EFI System Partition (512MB for GRUB UEFI)
parted -s "$NVME_DISK" mkpart primary fat32 3MiB 515MiB
parted -s "$NVME_DISK" set 2 esp on

# Partition 3: Swap (32GB)
parted -s "$NVME_DISK" mkpart primary linux-swap 515MiB 33299MiB

# Partition 4: OS Root / (Remaining space)
parted -s "$NVME_DISK" mkpart primary ext4 33299MiB 100%

partprobe "$NVME_DISK"
sleep 2

BIOS_PART="${NVME_PART_PREFIX}1"
EFI_PART="${NVME_PART_PREFIX}2"
SWAP_PART="${NVME_PART_PREFIX}3"
ROOT_PART="${NVME_PART_PREFIX}4"

echo "--> Formatting NVMe partitions..."
mkfs.vfat -F32 "$EFI_PART"
mkswap "$SWAP_PART"
swapon "$SWAP_PART"
mkfs.ext4 -F "$ROOT_PART"

echo "--> Mounting OS Root filesystem..."
mkdir -p /mnt/target
mount "$ROOT_PART" /mnt/target
mkdir -p /mnt/target/boot/efi
mount "$EFI_PART" /mnt/target/boot/efi

# --------------------------------------------------
# 4. Debootstrap Debian 11 (Bullseye) Core
# --------------------------------------------------
echo "--> Debootstrapping Debian 11 (Bullseye)..."
debootstrap --arch=amd64 bullseye /mnt/target http://deb.debian.org/debian/

# --------------------------------------------------
# 5. System Configuration & Network Setup
# --------------------------------------------------
echo "--> Mount pseudo-filesystems for Chroot..."
for dir in /dev /dev/pts /proc /sys /run; do
    mount --bind "$dir" "/mnt/target$dir"
done

echo "$HOSTNAME" > /mnt/target/etc/hostname

cat <<EOF > /mnt/target/etc/hosts
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
$IP_ADDR   $HOSTNAME
EOF

# Interface configuration (/etc/network/interfaces)
mkdir -p /mnt/target/etc/network
cat <<EOF > /mnt/target/etc/network/interfaces
auto lo
iface lo inet loopback

auto ${DETECTED_IFACE}
iface ${DETECTED_IFACE} inet static
    address ${IP_ADDR}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    dns-nameservers 1.1.1.1 8.8.8.8
EOF

# FSTAB configuration (NVMe OS only)
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")

cat <<EOF > /mnt/target/etc/fstab
UUID=${ROOT_UUID}   /              ext4    errors=remount-ro,noatime 0 1
UUID=${EFI_UUID}    /boot/efi      vfat    umask=0077                0 2
UUID=${SWAP_UUID}   none           swap    sw                        0 0
EOF

# Apt Sources List for Debian 11 Bullseye
cat <<EOF > /mnt/target/etc/apt/sources.list
deb http://deb.debian.org/debian/ bullseye main contrib non-free
deb-src http://deb.debian.org/debian/ bullseye main contrib non-free

deb http://security.debian.org/debian-security bullseye-security main contrib non-free
deb-src http://security.debian.org/debian-security bullseye-security main contrib non-free

deb http://deb.debian.org/debian/ bullseye-updates main contrib non-free
deb-src http://deb.debian.org/debian/ bullseye-updates main contrib non-free
EOF

# --------------------------------------------------
# 6. Chroot Operations (Kernel, GRUB & Password)
# --------------------------------------------------
echo "--> Executing Chroot Setup..."
chroot /mnt/target /bin/bash -s <<EOF
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y linux-image-amd64 linux-headers-amd64 firmware-linux-free firmware-linux-nonfree \
    openssh-server curl wget sudo net-tools grub-pc grub-efi-amd64

# Enable Root SSH Login
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# Set Root Password
echo "root:${ROOT_PASS}" | chpasswd

# Install Dual GRUB Bootloaders (Hybrid BIOS + UEFI support)
echo "--> Installing GRUB for Legacy BIOS..."
grub-install --target=i386-pc "$NVME_DISK" || true

echo "--> Installing GRUB for UEFI..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Debian --recheck || true

update-grub

systemctl enable ssh
EOF

# --------------------------------------------------
# 7. Cleanup
# --------------------------------------------------
echo "--> Cleaning up mounts..."
umount -R /mnt/target 2>/dev/null || true

echo "===================================================="
echo " Debian 11 (Bullseye) Installation Complete!"
echo " OS installed on: $NVME_DISK"
echo " HDDs wiped & ready for customer configuration."
echo " Run '# reboot' to start your new OS."
echo "===================================================="
