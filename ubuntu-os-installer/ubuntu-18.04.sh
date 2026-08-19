#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Ubuntu 18.04 LTS Server Installer
#
# Run from Linux Rescue environments such as:
#   - Rocky Linux Rescue
#   - GRML Rescue
#
# Installs:
#   Ubuntu 18.04 LTS (Bionic)
#
# WARNING:
#   The selected target disk will be COMPLETELY ERASED.
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OS_NAME="Ubuntu 18.04 LTS"
CODENAME="bionic"

# Ubuntu 18.04 is EOL.
UBUNTU_MIRROR="http://old-releases.ubuntu.com/ubuntu"

TARGET_MOUNT="/mnt/target"
WORK_DIR="/tmp/ubuntu-18-installer"

DEBOOTSTRAP_VERSION="1.0.141"
DEBOOTSTRAP_URL="https://deb.debian.org/debian/pool/main/d/debootstrap/debootstrap_${DEBOOTSTRAP_VERSION}_all.deb"

TARGET_DISK=""
ROOT_PART=""
EFI_PART=""

DEFAULT_IF=""
DEFAULT_IP=""
DEFAULT_PREFIX=""
DEFAULT_GW=""
DEFAULT_MAC=""

BOOT_MODE=""

trap 'echo; echo "ERROR: Installation stopped at line $LINENO."; exit 1' ERR


# ============================================================
# Basic functions
# ============================================================

die() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}


# ============================================================
# Root check
# ============================================================

check_root() {

    if [ "$(id -u)" -ne 0 ]; then
        die "This installer must be run as root."
    fi
}


# ============================================================
# Detect Rescue environment
# ============================================================

detect_rescue_os() {

    echo
    echo "============================================================"
    echo " Rescue Environment"
    echo "============================================================"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "OS      : ${PRETTY_NAME:-Unknown}"
        echo "Kernel  : $(uname -r)"
    else
        echo "OS      : Unknown"
    fi
}


# ============================================================
# Detect BIOS / UEFI
# ============================================================

detect_boot_mode() {

    echo
    echo "Detecting boot mode..."

    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi

    echo "Boot mode: $BOOT_MODE"
}


# ============================================================
# Check Rescue tools
# ============================================================

check_tools() {

    echo
    echo "============================================================"
    echo " Checking Rescue Tools"
    echo "============================================================"

    local required=(
        bash
        curl
        tar
        gzip
        awk
        sed
        grep
        mount
        umount
        chroot
        lsblk
        blkid
        wipefs
        parted
        mkfs.ext4
        ip
    )

    local missing=()

    for cmd in "${required[@]}"; do
        if command_exists "$cmd"; then
            echo "[OK]      $cmd"
        else
            echo "[MISSING] $cmd"
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        echo
        echo "All required Rescue tools are available."
        return
    fi

    echo
    echo "Missing tools: ${missing[*]}"

    if command_exists dnf; then

        echo "Attempting to install missing tools using DNF..."

        dnf install -y \
            curl \
            tar \
            gzip \
            xz \
            gawk \
            grep \
            util-linux \
            parted \
            e2fsprogs \
            coreutils \
            iproute

    elif command_exists apt-get; then

        echo "Attempting to install missing tools using APT..."

        apt-get update

        apt-get install -y \
            curl \
            tar \
            gzip \
            xz-utils \
            gawk \
            grep \
            util-linux \
            parted \
            e2fsprogs \
            coreutils \
            iproute2

    else
        die "Cannot install missing Rescue tools automatically."
    fi
}


# ============================================================
# Detect network
# ============================================================

detect_network() {

    echo
    echo "============================================================"
    echo " Detecting Network"
    echo "============================================================"

    DEFAULT_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"

    [ -n "$DEFAULT_IF" ] ||
        die "Could not detect the interface carrying the default route."

    DEFAULT_IP="$(
        ip -4 -o addr show dev "$DEFAULT_IF" |
        awk 'NR==1 {print $4}' |
        cut -d/ -f1
    )"

    DEFAULT_PREFIX="$(
        ip -4 -o addr show dev "$DEFAULT_IF" |
        awk 'NR==1 {print $4}' |
        cut -d/ -f2
    )"

    DEFAULT_GW="$(
        ip -4 route show default dev "$DEFAULT_IF" |
        awk 'NR==1 {print $3}'
    )"

    DEFAULT_MAC="$(cat "/sys/class/net/$DEFAULT_IF/address")"

    [ -n "$DEFAULT_IP" ] ||
        die "Could not determine IPv4 address."

    [ -n "$DEFAULT_PREFIX" ] ||
        die "Could not determine network prefix."

    [ -n "$DEFAULT_GW" ] ||
        die "Could not determine gateway."

    echo
    echo "Interface : $DEFAULT_IF"
    echo "MAC       : $DEFAULT_MAC"
    echo "IP        : $DEFAULT_IP"
    echo "Prefix    : /$DEFAULT_PREFIX"
    echo "Gateway   : $DEFAULT_GW"
}


# ============================================================
# Prefix → Netmask
# ============================================================

prefix_to_netmask() {

    local prefix="$1"
    local mask=""
    local octet

    if [ "$prefix" -eq 0 ]; then
        echo "0.0.0.0"
        return
    fi

    for octet in 1 2 3 4; do

        if [ "$prefix" -ge 8 ]; then
            mask="${mask}255"
            prefix=$((prefix - 8))

        elif [ "$prefix" -gt 0 ]; then
            mask="$mask$((256 - 2 ** (8 - prefix)))"
            prefix=0

        else
            mask="${mask}0"
        fi

        if [ "$octet" -lt 4 ]; then
            mask="${mask}."
        fi
    done

    echo "$mask"
}


# ============================================================
# Select installation disk
# ============================================================

select_target_disk() {

    echo
    echo "============================================================"
    echo " Available Physical Disks"
    echo "============================================================"
    echo

    lsblk -d -e 7 \
        -o NAME,SIZE,TYPE,MODEL,SERIAL

    echo
    echo "Select the disk where Ubuntu 18.04 will be installed."
    echo
    echo "WARNING: EVERYTHING on the selected disk will be erased."
    echo

    read -rp "Target disk (example: /dev/sda): " TARGET_DISK

    [ -b "$TARGET_DISK" ] ||
        die "$TARGET_DISK is not a valid block device."

    local disk_type

    disk_type="$(lsblk -dn -o TYPE "$TARGET_DISK")"

    [ "$disk_type" = "disk" ] ||
        die "$TARGET_DISK is not a physical disk."

    local disk_size
    local disk_model
    local disk_serial

    disk_size="$(lsblk -dn -o SIZE "$TARGET_DISK")"
    disk_model="$(lsblk -dn -o MODEL "$TARGET_DISK" | xargs)"
    disk_serial="$(lsblk -dn -o SERIAL "$TARGET_DISK" | xargs)"

    echo
    echo "============================================================"
    echo " Selected Installation Disk"
    echo "============================================================"
    echo
    echo "Device : $TARGET_DISK"
    echo "Size   : $disk_size"
    echo "Model  : $disk_model"
    echo "Serial : $disk_serial"
    echo

    echo "ALL DATA ON THIS DISK WILL BE DESTROYED."
    echo

    read -rp "Type INSTALL to continue: " confirmation

    [ "$confirmation" = "INSTALL" ] ||
        die "Installation cancelled."
}


# ============================================================
# Check target disk
# ============================================================

check_target_disk() {

    echo
    echo "Checking target disk..."

    local mounted

    mounted="$(
        lsblk -nr -o MOUNTPOINT "$TARGET_DISK" |
        grep -v '^$' || true
    )"

    if [ -n "$mounted" ]; then
        echo
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK"
        die "Target disk has mounted filesystems."
    fi

    echo "[OK] Target disk is not mounted."
}


# ============================================================
# Download / install debootstrap
# ============================================================

install_debootstrap() {

    if command_exists debootstrap; then

        echo
        echo "debootstrap already available."

        debootstrap --version || true

        return
    fi

    echo
    echo "============================================================"
    echo " Installing debootstrap"
    echo "============================================================"

    mkdir -p "$WORK_DIR"

    local deb="$WORK_DIR/debootstrap.deb"

    echo "Downloading:"
    echo "$DEBOOTSTRAP_URL"
    echo

    curl -fL --retry 3 \
        "$DEBOOTSTRAP_URL" \
        -o "$deb"

    [ -s "$deb" ] ||
        die "Failed to download debootstrap package."

    echo
    echo "Extracting debootstrap package..."

    rm -rf "$WORK_DIR/debootstrap-extract"

    mkdir -p "$WORK_DIR/debootstrap-extract"

    if command_exists dpkg-deb; then

        dpkg-deb -x "$deb" "$WORK_DIR/debootstrap-extract"

    else

        mkdir -p "$WORK_DIR/deb-control"

        cd "$WORK_DIR/deb-control"

        ar x "$deb"

        mkdir -p "$WORK_DIR/data"

        tar -xf data.tar.* \
            -C "$WORK_DIR/data"

        cp -a "$WORK_DIR/data/usr/sbin/debootstrap" \
            "$WORK_DIR/debootstrap-extract/" \
            2>/dev/null || true

        mkdir -p "$WORK_DIR/debootstrap-extract/usr/sbin"

        cp -a "$WORK_DIR/data/usr/sbin/debootstrap" \
            "$WORK_DIR/debootstrap-extract/usr/sbin/"
    fi

    if [ ! -f "$WORK_DIR/debootstrap-extract/usr/sbin/debootstrap" ]; then
        die "Could not extract debootstrap."
    fi

    cp "$WORK_DIR/debootstrap-extract/usr/sbin/debootstrap" \
        /usr/local/sbin/debootstrap

    chmod 755 /usr/local/sbin/debootstrap

    # Copy supporting files if available.
    if [ -d "$WORK_DIR/debootstrap-extract/usr/share/debootstrap" ]; then

        rm -rf /usr/local/share/debootstrap

        mkdir -p /usr/local/share

        cp -a \
            "$WORK_DIR/debootstrap-extract/usr/share/debootstrap" \
            /usr/local/share/
    fi

    echo
    echo "debootstrap installed."

    debootstrap --version || true
}


# ============================================================
# Partition disk
# ============================================================

partition_disk() {

    echo
    echo "============================================================"
    echo " Partitioning $TARGET_DISK"
    echo "============================================================"

    wipefs -a "$TARGET_DISK"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        echo "Creating GPT partition table for UEFI..."

        parted -s "$TARGET_DISK" mklabel gpt

        parted -s "$TARGET_DISK" \
            mkpart ESP fat32 1MiB 513MiB

        parted -s "$TARGET_DISK" \
            set 1 esp on

        parted -s "$TARGET_DISK" \
            mkpart root ext4 513MiB 100%

        if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
            EFI_PART="${TARGET_DISK}p1"
            ROOT_PART="${TARGET_DISK}p2"
        else
            EFI_PART="${TARGET_DISK}1"
            ROOT_PART="${TARGET_DISK}2"
        fi

    else

        echo "Creating GPT partition table for BIOS..."

        parted -s "$TARGET_DISK" mklabel gpt

        # BIOS Boot Partition.
        parted -s "$TARGET_DISK" \
            mkpart bios_grub 1MiB 3MiB

        parted -s "$TARGET_DISK" \
            set 1 bios_grub on

        parted -s "$TARGET_DISK" \
            mkpart root ext4 3MiB 100%

        if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
            ROOT_PART="${TARGET_DISK}p2"
        else
            ROOT_PART="${TARGET_DISK}2"
        fi
    fi

    sync
    sleep 2

    echo
    lsblk "$TARGET_DISK"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        echo
        echo "Formatting EFI partition..."

        mkfs.fat -F32 "$EFI_PART"

    fi

    echo
    echo "Formatting root partition..."

    mkfs.ext4 -F -L rootfs "$ROOT_PART"

    sync
}


# ============================================================
# Mount target
# ============================================================

mount_target() {

    echo
    echo "Mounting target filesystem..."

    mkdir -p "$TARGET_MOUNT"

    mount "$ROOT_PART" "$TARGET_MOUNT"

    mountpoint -q "$TARGET_MOUNT" ||
        die "Could not mount root filesystem."

    if [ "$BOOT_MODE" = "UEFI" ]; then

        mkdir -p "$TARGET_MOUNT/boot/efi"

        mount "$EFI_PART" "$TARGET_MOUNT/boot/efi"
    fi
}


# ============================================================
# Run debootstrap
# ============================================================

run_debootstrap() {

    echo
    echo "============================================================"
    echo " Installing Ubuntu 18.04"
    echo "============================================================"
    echo

    debootstrap \
        --arch=amd64 \
        "$CODENAME" \
        "$TARGET_MOUNT" \
        "$UBUNTU_MIRROR"

    echo
    echo "Ubuntu base system installed."
}


# ============================================================
# Bind Rescue filesystems
# ============================================================

bind_mounts() {

    echo
    echo "Preparing chroot environment..."

    mount --rbind /dev "$TARGET_MOUNT/dev"
    mount --make-rslave "$TARGET_MOUNT/dev"

    mount --rbind /proc "$TARGET_MOUNT/proc"
    mount --make-rslave "$TARGET_MOUNT/proc"

    mount --rbind /sys "$TARGET_MOUNT/sys"
    mount --make-rslave "$TARGET_MOUNT/sys"

    if [ -d /run ]; then

        mount --rbind /run "$TARGET_MOUNT/run"
        mount --make-rslave "$TARGET_MOUNT/run"
    fi

    rm -f "$TARGET_MOUNT/etc/resolv.conf"

    cp -L /etc/resolv.conf \
        "$TARGET_MOUNT/etc/resolv.conf"
}


# ============================================================
# Configure Ubuntu
# ============================================================

configure_ubuntu() {

    echo
    echo "============================================================"
    echo " Configuring Ubuntu 18.04"
    echo "============================================================"

    local root_uuid
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"

    [ -n "$root_uuid" ] ||
        die "Could not determine root filesystem UUID."

    local netmask
    netmask="$(prefix_to_netmask "$DEFAULT_PREFIX")"

    echo
    echo "Root UUID : $root_uuid"
    echo "Netmask   : $netmask"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        local efi_uuid
        efi_uuid="$(blkid -s UUID -o value "$EFI_PART")"

        cat > "$TARGET_MOUNT/etc/fstab" <<EOF
UUID=$root_uuid / ext4 errors=remount-ro 0 1
UUID=$efi_uuid /boot/efi vfat umask=0077 0 1
EOF

    else

        cat > "$TARGET_MOUNT/etc/fstab" <<EOF
UUID=$root_uuid / ext4 errors=remount-ro 0 1
EOF

    fi

    cat > "$TARGET_MOUNT/etc/apt/sources.list" <<EOF
deb http://old-releases.ubuntu.com/ubuntu/ bionic main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ bionic-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ bionic-security main restricted universe multiverse
EOF

    cat > "$TARGET_MOUNT/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto $DEFAULT_IF
iface $DEFAULT_IF inet static
    address $DEFAULT_IP
    netmask $netmask
    gateway $DEFAULT_GW
    dns-nameservers 8.8.8.8 1.1.1.1
EOF

    echo "ubuntu-server" > "$TARGET_MOUNT/etc/hostname"

    cat > "$TARGET_MOUNT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ubuntu-server

::1 localhost ip6-localhost ip6-loopback
EOF

    chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    linux-image-generic \
    openssh-server \
    sudo \
    ifupdown \
    net-tools \
    iproute2 \
    ca-certificates

systemctl enable ssh
systemctl enable networking

update-initramfs -c -k all

CHROOT
}


# ============================================================
# Configure root password
# ============================================================

configure_root_password() {

    echo
    echo "============================================================"
    echo " Root Password"
    echo "============================================================"
    echo
    echo "Set the root password for the new Ubuntu installation."
    echo

    local password1
    local password2

    while true; do

        read -rsp "New root password: " password1
        echo

        read -rsp "Confirm root password: " password2
        echo

        if [ -z "$password1" ]; then
            echo "Password cannot be empty."
            continue
        fi

        if [ "$password1" != "$password2" ]; then
            echo "Passwords do not match."
            continue
        fi

        break
    done

    printf '%s\n%s\n' "$password1" "$password1" |
        chroot "$TARGET_MOUNT" passwd root

    unset password1
    unset password2
}


# ============================================================
# Install GRUB
# ============================================================

install_grub() {

    echo
    echo "============================================================"
    echo " Installing GRUB"
    echo "============================================================"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        echo "Installing UEFI GRUB..."

        chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export DEBIAN_FRONTEND=noninteractive

apt-get install -y \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    shim-signed \
    dosfstools

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ubuntu \
    --recheck

update-grub

CHROOT

    else

        echo "Installing BIOS GRUB..."

        chroot "$TARGET_MOUNT" /bin/bash <<CHROOT
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export DEBIAN_FRONTEND=noninteractive

apt-get install -y grub-pc

grub-install \
    --target=i386-pc \
    --recheck \
    "$TARGET_DISK"

update-grub

CHROOT

    fi

    echo
    echo "GRUB installation completed."
}


# ============================================================
# Verify installation
# ============================================================

verify_installation() {

    echo
    echo "============================================================"
    echo " Installation Verification"
    echo "============================================================"

    echo
    echo "Boot mode:"
    echo "$BOOT_MODE"

    echo
    echo "Target disk:"
    echo "$TARGET_DISK"

    echo
    echo "Root partition:"
    echo "$ROOT_PART"

    echo
    echo "Filesystem:"
    blkid "$ROOT_PART"

    if [ "$BOOT_MODE" = "UEFI" ]; then
        echo
        echo "EFI partition:"
        echo "$EFI_PART"

        blkid "$EFI_PART"
    fi

    echo
    echo "Kernel:"
    ls -lh "$TARGET_MOUNT"/boot/vmlinuz-* || true

    echo
    echo "Initramfs:"
    ls -lh "$TARGET_MOUNT"/boot/initrd.img-* || true

    echo
    echo "fstab:"
    cat "$TARGET_MOUNT/etc/fstab"

    echo
    echo "Network:"
    cat "$TARGET_MOUNT/etc/network/interfaces"

    echo
    echo "OS:"
    cat "$TARGET_MOUNT/etc/os-release"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        if [ -d "$TARGET_MOUNT/boot/efi/EFI/ubuntu" ]; then
            echo
            echo "[OK] UEFI Ubuntu boot files found."
        else
            die "UEFI boot files were not found."
        fi

    else

        if [ -f "$TARGET_MOUNT/boot/grub/i386-pc/core.img" ]; then
            echo
            echo "[OK] BIOS GRUB core.img found."
        else
            die "BIOS GRUB core.img was not found."
        fi
    fi

    echo
    echo "Verification completed."
}


# ============================================================
# Cleanup
# ============================================================

cleanup() {

    echo
    echo "Cleaning up..."

    sync

    if [ "$BOOT_MODE" = "UEFI" ]; then

        if mountpoint -q "$TARGET_MOUNT/boot/efi"; then
            umount "$TARGET_MOUNT/boot/efi" || true
        fi

    fi

    if mountpoint -q "$TARGET_MOUNT/run"; then
        umount -R "$TARGET_MOUNT/run" || true
    fi

    if mountpoint -q "$TARGET_MOUNT/sys"; then
        umount -R "$TARGET_MOUNT/sys" || true
    fi

    if mountpoint -q "$TARGET_MOUNT/proc"; then
        umount -R "$TARGET_MOUNT/proc" || true
    fi

    if mountpoint -q "$TARGET_MOUNT/dev"; then
        umount -R "$TARGET_MOUNT/dev" || true
    fi

    if mountpoint -q "$TARGET_MOUNT"; then
        umount "$TARGET_MOUNT"
    fi

    rm -rf "$WORK_DIR"

    sync

    echo
    echo "Cleanup completed."
}


# ============================================================
# Main
# ============================================================

clear

echo
echo "============================================================"
echo "        UBUNTU 18.04 LTS SERVER INSTALLER"
echo "============================================================"
echo
echo "This installer will erase the selected disk."
echo
echo "Target OS : Ubuntu 18.04 LTS"
echo "Codename  : Bionic"
echo

check_root
detect_rescue_os
detect_boot_mode
check_tools
detect_network
select_target_disk
check_target_disk
install_debootstrap

echo
echo "============================================================"
echo " FINAL INSTALLATION SUMMARY"
echo "============================================================"
echo
echo "Target disk : $TARGET_DISK"
echo "Boot mode   : $BOOT_MODE"
echo "Network     : $DEFAULT_IF"
echo "IP address  : $DEFAULT_IP/$DEFAULT_PREFIX"
echo "Gateway     : $DEFAULT_GW"
echo
echo "Ubuntu 18.04 will now be installed."
echo

read -rp "Type INSTALL again to begin disk partitioning: " FINAL_CONFIRM

[ "$FINAL_CONFIRM" = "INSTALL" ] ||
    die "Installation cancelled."

partition_disk
mount_target
run_debootstrap
bind_mounts
configure_ubuntu
configure_root_password
install_grub
verify_installation

echo
echo "============================================================"
echo " Ubuntu 18.04 Installation Completed"
echo "============================================================"
echo
echo "Target disk : $TARGET_DISK"
echo "Boot mode   : $BOOT_MODE"
echo "Network     : $DEFAULT_IF"
echo "IP          : $DEFAULT_IP"
echo
echo "The server is ready to reboot."
echo

read -rp "Reboot into Ubuntu 18.04 now? [y/N]: " REBOOT_CONFIRM

if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then

    cleanup

    echo
    echo "Rebooting into Ubuntu 18.04..."
    sleep 3

    reboot

else

    cleanup

    echo
    echo "Reboot cancelled."
    echo "You can reboot manually when ready."
fi
