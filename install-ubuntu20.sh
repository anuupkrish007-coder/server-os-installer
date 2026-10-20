#!/usr/bin/env bash
set -eo pipefail

echo "===================================================="
echo "  Ubuntu 20.04 LTS (Focal) Installer (NVMe OS Only)"
echo "  Target: 1x NVMe/SSD (OS) + Pass-Through Raw HDDs"
echo "===================================================="

# --------------------------------------------------
# 1. Environment & Package Manager Detection
# --------------------------------------------------
echo "--> Checking host environment package manager..."
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
else
    echo "ERROR: Unknown package manager on rescue environment!"
    exit 1
fi

REQUIRED_TOOLS=("parted" "debootstrap" "gdisk" "ip")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "--> Installing missing tool: $tool..."
        if [ "$PKG_MGR" = "apt" ]; then
            apt-get update -qq && apt-get install -y -qq "$tool" net-tools iproute2 || true
        else
            $PKG_MGR install -y epel-release 2>/dev/null || true
            $PKG_MGR install -y "$tool" net-tools iproute 2>/dev/null || true
        fi
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
DETECTED_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || true)
if [ -z "$DETECTED_IFACE" ]; then
    DETECTED_IFACE=$(ip route | grep default | grep -oP 'dev \K\S+' | head -n1)
fi

MAC_ADDR=$(cat /sys/class/net/${DETECTED_IFACE}/address 2>/dev/null || true)

read -rp "Enter OS Disk Name (e.g., sdb, nvme0n1): " OS_INPUT
OS_INPUT=$(echo "$OS_INPUT" | sed 's|^/dev/||')
OS_DISK="/dev/${OS_INPUT}"

if [ ! -b "$OS_DISK" ]; then
    echo "ERROR: Device $OS_DISK does not exist!"
    exit 1
fi

echo "Enter HDD names to wipe partition tables for pass-through (separated by space, e.g., sda sdc sdd):"
read -rp "> " -a HDD_INPUTS

HDD_DISKS=()
for hdd in "${HDD_INPUTS[@]}"; do
    clean_hdd=$(echo "$hdd" | sed 's|^/dev/||')
    if [ -b "/dev/${clean_hdd}" ]; then
        HDD_DISKS+=("/dev/${clean_hdd}")
    fi
done

read -rp "Enter Hostname [ubuntu-node]: " HOSTNAME
HOSTNAME=${HOSTNAME:-ubuntu-node}

read -rp "Enter Server Public IP: " IP_ADDR
read -rp "Enter Subnet Netmask (e.g., 255.255.255.192): " NETMASK
read -rp "Enter Default Gateway IP: " GATEWAY
read -rsp "Enter Root Password for Ubuntu 20.04: " ROOT_PASS
echo ""

# Convert netmask to CIDR prefix
cdr() {
    local x=${1##*255.}
    set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
    x=${1%%$3*}
    echo $(( $2 + (${#x}/4) ))
}
CIDR_PREFIX=$(cdr "$NETMASK")

echo ""
echo "===================================================="
echo " Summary of Installation Settings:"
echo " OS:              Ubuntu 20.04 LTS (Focal)"
echo " Boot Mode:       $( [ $IS_EFI -eq 1 ] && echo 'UEFI' || echo 'Legacy BIOS' )"
echo " OS Drive:        $OS_DISK"
echo " Pass-Through:    ${HDD_DISKS[*]} (Unformatted / Raw)"
echo " Interface:       $DETECTED_IFACE ($MAC_ADDR)"
echo " Hostname:        $HOSTNAME"
echo " IP Address:      $IP_ADDR/${CIDR_PREFIX}"
echo " Gateway:         $GATEWAY"
echo "===================================================="
read -rp "WARNING: ALL DATA ON OS DISK ($OS_DISK) AND HDDs WILL BE ERASED! Proceed? (type YES): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# --------------------------------------------------
# 3. Partition Target Drive
# --------------------------------------------------
echo "--> Unmounting existing target mounts..."
umount -R /mnt/target 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo "--> Wiping partition headers on OS Disk..."
dd if=/dev/zero of="$OS_DISK" bs=1M count=20 status=none

for hdd in "${HDD_DISKS[@]}"; do
    echo "--> Wiping signature on raw drive $hdd..."
    dd if=/dev/zero of="$hdd" bs=1M count=20 status=none
    parted -s "$hdd" mklabel gpt || true
done
sync

if [[ "$OS_INPUT" =~ [0-9]$ ]]; then
    OS_PART_PREFIX="${OS_DISK}p"
else
    OS_PART_PREFIX="${OS_DISK}"
fi

echo "--> Setting up GPT Scheme on $OS_DISK..."
parted -s "$OS_DISK" mklabel gpt

if [ $IS_EFI -eq 1 ]; then
    # EFI Partitioning
    parted -s "$OS_DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$OS_DISK" set 1 esp on

    parted -s "$OS_DISK" mkpart primary linux-swap 513MiB 33281MiB
    parted -s "$OS_DISK" mkpart primary ext4 33281MiB 100%

    partprobe "$OS_DISK"
    sleep 2

    EFI_PART="${OS_PART_PREFIX}1"
    SWAP_PART="${OS_PART_PREFIX}2"
    ROOT_PART="${OS_PART_PREFIX}3"

    echo "--> Formatting partitions..."
    mkfs.vfat -F32 "$EFI_PART"
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
    mkfs.ext4 -F "$ROOT_PART"

    echo "--> Mounting OS Root filesystem..."
    mkdir -p /mnt/target
    mount "$ROOT_PART" /mnt/target
    mkdir -p /mnt/target/boot/efi
    mount "$EFI_PART" /mnt/target/boot/efi
else
    # Legacy BIOS Partitioning
    parted -s "$OS_DISK" mkpart primary 1MiB 3MiB
    parted -s "$OS_DISK" set 1 bios_grub on

    parted -s "$OS_DISK" mkpart primary linux-swap 3MiB 32771MiB
    parted -s "$OS_DISK" mkpart primary ext4 32771MiB 100%

    partprobe "$OS_DISK"
    sleep 2

    BIOS_PART="${OS_PART_PREFIX}1"
    SWAP_PART="${OS_PART_PREFIX}2"
    ROOT_PART="${OS_PART_PREFIX}3"

    echo "--> Formatting partitions..."
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
    mkfs.ext4 -F "$ROOT_PART"

    echo "--> Mounting OS Root filesystem..."
    mkdir -p /mnt/target
    mount "$ROOT_PART" /mnt/target
fi

# --------------------------------------------------
# 4. Debootstrap Ubuntu 20.04 (Focal Fossa) Core
# --------------------------------------------------
echo "--> Debootstrapping Ubuntu 20.04 (Focal)..."
debootstrap --arch=amd64 focal /mnt/target http://archive.ubuntu.com/ubuntu/

# --------------------------------------------------
# 5. System Configuration & Netplan Setup
# --------------------------------------------------
echo "--> Mounting pseudo-filesystems for Chroot..."
for dir in /dev /dev/pts /proc /sys /run; do
    mount --bind "$dir" "/mnt/target$dir"
done

echo "$HOSTNAME" > /mnt/target/etc/hostname

cat <<EOF > /mnt/target/etc/hosts
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
$IP_ADDR   $HOSTNAME
EOF

# Ubuntu 20.04 uses Netplan
mkdir -p /mnt/target/etc/netplan
cat <<EOF > /mnt/target/etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ${DETECTED_IFACE}:
      addresses:
        - ${IP_ADDR}/${CIDR_PREFIX}
      gateway4: ${GATEWAY}
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
EOF

chmod 600 /mnt/target/etc/netplan/01-netcfg.yaml

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")

if [ $IS_EFI -eq 1 ]; then
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    cat <<EOF > /mnt/target/etc/fstab
UUID=${ROOT_UUID}   /              ext4    errors=remount-ro,noatime 0 1
UUID=${EFI_UUID}    /boot/efi      vfat    umask=0077                0 2
UUID=${SWAP_UUID}   none           swap    sw                        0 0
EOF
else
    cat <<EOF > /mnt/target/etc/fstab
UUID=${ROOT_UUID}   /              ext4    errors=remount-ro,noatime 0 1
UUID=${SWAP_UUID}   none           swap    sw                        0 0
EOF
fi

# Ubuntu Official Repositories
cat <<EOF > /mnt/target/etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse
EOF

# --------------------------------------------------
# 6. Chroot Operations (Kernel, GRUB & Password)
# --------------------------------------------------
echo "--> Executing Chroot Setup..."
chroot /mnt/target /bin/bash -s <<EOF
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y linux-generic linux-headers-generic openssh-server curl wget sudo net-tools netplan.io

if [ $IS_EFI -eq 1 ]; then
    echo "--> Installing UEFI packages..."
    apt-get install -y grub-efi-amd64
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
else
    echo "--> Installing Legacy BIOS packages..."
    apt-get install -y grub-pc
    grub-install --target=i386-pc "$OS_DISK"
fi

update-grub

# Enable Root SSH Login
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# Set Root Password
echo "root:${ROOT_PASS}" | chpasswd

systemctl enable ssh
systemctl enable systemd-networkd
EOF

# --------------------------------------------------
# 7. Cleanup
# --------------------------------------------------
echo "--> Cleaning up mounts..."
umount -R /mnt/target 2>/dev/null || true

echo "===================================================="
echo " Ubuntu 20.04 LTS Installation Complete!"
echo " OS installed on: $OS_DISK"
echo " HDDs wiped & ready for customer configuration."
echo " Run '# reboot' to start your new OS."
echo "===================================================="
