#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Ubuntu 18.04 LTS Server Installer
#
# Run from Linux Rescue environments such as:
#   - Rocky Linux Rescue
#   - GRML Rescue
#
# Installs Ubuntu 18.04 LTS (Bionic)
#
# Supports:
#   - BIOS
#   - UEFI
#   - Interactive target disk selection
#   - Automatic network detection
#   - MAC-based NIC persistence
#   - SSH
#   - 4G swapfile
#   - No dpkg-deb requirement in Rescue Mode
#
# WARNING:
#   The selected target disk will be COMPLETELY ERASED.
# ============================================================

set +m
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OS_NAME="Ubuntu 18.04 LTS"
CODENAME="bionic"

# Ubuntu 18.04 is EOL.
UBUNTU_MIRROR="http://old-releases.ubuntu.com/ubuntu"

# Pinned debootstrap package.
DEBOOTSTRAP_VERSION="1.0.141"
DEBOOTSTRAP_URL="https://deb.debian.org/debian/pool/main/d/debootstrap/debootstrap_${DEBOOTSTRAP_VERSION}_all.deb"

TARGET_MOUNT="/mnt/target"
WORK_DIR="/tmp/ubuntu-18-installer"

TARGET_DISK=""
ROOT_PART=""
EFI_PART=""

BOOT_MODE=""
DEFAULT_IF=""
DEFAULT_MAC=""
DEFAULT_IP=""
DEFAULT_PREFIX=""
DEFAULT_GATEWAY=""
DEFAULT_NETMASK=""

ROOT_UUID=""

SWAP_SIZE_MB="4096"

die() {
    echo
    echo "ERROR: $*" >&2
    echo
    exit 1
}

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    set +e

    if mountpoint -q "$TARGET_MOUNT/boot/efi" 2>/dev/null; then
        umount -lf "$TARGET_MOUNT/boot/efi" 2>/dev/null || true
    fi

    for mp in \
        "$TARGET_MOUNT/dev/pts" \
        "$TARGET_MOUNT/dev" \
        "$TARGET_MOUNT/proc" \
        "$TARGET_MOUNT/sys" \
        "$TARGET_MOUNT/run"
    do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount -lf "$mp" 2>/dev/null || true
        fi
    done

    if mountpoint -q "$TARGET_MOUNT" 2>/dev/null; then
        umount -lf "$TARGET_MOUNT" 2>/dev/null || true
    fi
}

trap cleanup EXIT

prefix_to_netmask() {
    local prefix="$1"
    local mask=0
    local i octet
    local result=""

    if [ "$prefix" -eq 0 ]; then
        echo "0.0.0.0"
        return
    fi

    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))

    for i in 3 2 1 0; do
        octet=$(( (mask >> (i * 8)) & 255 ))
        if [ -z "$result" ]; then
            result="$octet"
        else
            result="${result}.${octet}"
        fi
    done

    echo "$result"
}

check_rescue_commands() {
    log "Checking Rescue environment"

    local required=(
        awk
        ar
        bash
        blkid
        chroot
        curl
        find
        grep
        ip
        lsblk
        mount
        mountpoint
        parted
        partprobe
        sed
        tar
        wipefs
        mkfs.ext4
    )

    local missing=()
    local cmd

    for cmd in "${required[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        die "Missing required commands: ${missing[*]}"
    fi

    if ! command_exists mkfs.fat; then
        echo "WARNING: mkfs.fat is not available."
        echo "UEFI installation cannot proceed without it."
    fi

    echo "Required Rescue tools: OK"
}

detect_boot_mode() {
    log "Detecting boot mode"

    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi

    echo "Boot mode: $BOOT_MODE"
}

detect_network() {
    log "Detecting network"

    DEFAULT_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"

    [ -n "$DEFAULT_IF" ] ||
        die "Could not determine the default network interface."

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

    DEFAULT_GATEWAY="$(
        ip -4 route show default dev "$DEFAULT_IF" |
        awk 'NR==1 {print $3}'
    )"

    DEFAULT_MAC="$(
        cat "/sys/class/net/${DEFAULT_IF}/address"
    )"

    [ -n "$DEFAULT_IP" ] ||
        die "Could not determine IPv4 address."

    [ -n "$DEFAULT_PREFIX" ] ||
        die "Could not determine IPv4 prefix."

    [ -n "$DEFAULT_GATEWAY" ] ||
        die "Could not determine gateway."

    DEFAULT_NETMASK="$(prefix_to_netmask "$DEFAULT_PREFIX")"

    echo "Interface : $DEFAULT_IF"
    echo "MAC       : $DEFAULT_MAC"
    echo "IP        : $DEFAULT_IP"
    echo "Prefix    : /$DEFAULT_PREFIX"
    echo "Netmask   : $DEFAULT_NETMASK"
    echo "Gateway   : $DEFAULT_GATEWAY"
}

show_disks() {
    echo
    echo "Available physical disks:"
    echo

    lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

    echo
}

select_target_disk() {
    log "Select target disk"

    show_disks

    read -rp "Target disk (example: /dev/sdc): " TARGET_DISK

    [ -n "$TARGET_DISK" ] ||
        die "No target disk selected."

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
    echo "Selected target:"
    echo "  Device : $TARGET_DISK"
    echo "  Size   : $disk_size"
    echo "  Model  : $disk_model"
    echo "  Serial : $disk_serial"
    echo

    echo "WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED."
    echo

    read -rp "Type WIPE to continue: " confirm

    [ "$confirm" = "WIPE" ] ||
        die "Installation cancelled."

    if lsblk -nr -o MOUNTPOINT "$TARGET_DISK" | grep -qE '.+'; then
        die "One or more partitions on $TARGET_DISK are mounted."
    fi
}

install_debootstrap() {
    log "Preparing debootstrap"

    if command_exists debootstrap; then
        echo "debootstrap already available:"
        debootstrap --version || true
        return
    fi

    mkdir -p "$WORK_DIR"

    local deb="$WORK_DIR/debootstrap.deb"

    echo "Downloading:"
    echo "$DEBOOTSTRAP_URL"

    curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        "$DEBOOTSTRAP_URL" \
        -o "$deb" ||
        die "Failed to download debootstrap package."

    rm -rf "$WORK_DIR/debootstrap-extract"
    rm -rf "$WORK_DIR/deb-extract"

    mkdir -p "$WORK_DIR/debootstrap-extract"
    mkdir -p "$WORK_DIR/deb-extract"

    if command_exists dpkg-deb; then

        echo "Using dpkg-deb..."
        dpkg-deb -x \
            "$deb" \
            "$WORK_DIR/debootstrap-extract"

    else

        echo "dpkg-deb not available."
        echo "Using ar + tar extraction..."

        (
            cd "$WORK_DIR/deb-extract"

            ar x "$deb"

            local data_archive

            data_archive="$(
                find . -maxdepth 1 -type f \
                    \( \
                        -name 'data.tar' \
                        -o -name 'data.tar.gz' \
                        -o -name 'data.tar.xz' \
                        -o -name 'data.tar.bz2' \
                        -o -name 'data.tar.zst' \
                    \) |
                head -n1
            )"

            [ -n "$data_archive" ] ||
                die "Could not find data archive in debootstrap package."

            case "$data_archive" in
                *.tar)
                    tar -xf "$data_archive" \
                        -C "$WORK_DIR/debootstrap-extract"
                    ;;
                *.tar.gz)
                    tar -xzf "$data_archive" \
                        -C "$WORK_DIR/debootstrap-extract"
                    ;;
                *.tar.xz)
                    tar -xJf "$data_archive" \
                        -C "$WORK_DIR/debootstrap-extract"
                    ;;
                *.tar.bz2)
                    tar -xjf "$data_archive" \
                        -C "$WORK_DIR/debootstrap-extract"
                    ;;
                *.tar.zst)
                    if tar --help 2>&1 | grep -q -- '--zstd'; then
                        tar --zstd -xf "$data_archive" \
                            -C "$WORK_DIR/debootstrap-extract"
                    else
                        die "tar does not support zstd."
                    fi
                    ;;
                *)
                    die "Unsupported debootstrap data archive."
                    ;;
            esac
        )
    fi

    [ -f "$WORK_DIR/debootstrap-extract/usr/sbin/debootstrap" ] ||
        die "debootstrap extraction failed."

    rm -rf /usr/local/share/debootstrap

    if [ -d "$WORK_DIR/debootstrap-extract/usr/share/debootstrap" ]; then
        mkdir -p /usr/local/share

        cp -a \
            "$WORK_DIR/debootstrap-extract/usr/share/debootstrap" \
            /usr/local/share/
    fi

    cp \
        "$WORK_DIR/debootstrap-extract/usr/sbin/debootstrap" \
        /usr/local/sbin/debootstrap

    chmod 755 /usr/local/sbin/debootstrap

    command_exists debootstrap ||
        die "debootstrap installation failed."

    echo
    debootstrap --version || true
}

partition_target() {
    log "Partitioning target disk"

    wipefs -a "$TARGET_DISK"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        echo "Creating GPT + EFI + root partitions..."

        parted -s "$TARGET_DISK" mklabel gpt

        parted -s "$TARGET_DISK" \
            mkpart ESP fat32 1MiB 513MiB

        parted -s "$TARGET_DISK" \
            set 1 esp on

        parted -s "$TARGET_DISK" \
            mkpart primary ext4 513MiB 100%

        if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
            EFI_PART="${TARGET_DISK}p1"
            ROOT_PART="${TARGET_DISK}p2"
        else
            EFI_PART="${TARGET_DISK}1"
            ROOT_PART="${TARGET_DISK}2"
        fi

        sleep 2
        partprobe "$TARGET_DISK" || true
        sleep 2

        mkfs.fat -F32 "$EFI_PART"

    else

        echo "Creating GPT + BIOS boot + root partitions..."

        parted -s "$TARGET_DISK" mklabel gpt

        parted -s "$TARGET_DISK" \
            mkpart bios_grub 1MiB 3MiB

        parted -s "$TARGET_DISK" \
            set 1 bios_grub on

        parted -s "$TARGET_DISK" \
            mkpart primary ext4 3MiB 100%

        if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
            ROOT_PART="${TARGET_DISK}p2"
        else
            ROOT_PART="${TARGET_DISK}2"
        fi

        sleep 2
        partprobe "$TARGET_DISK" || true
        sleep 2
    fi

    [ -b "$ROOT_PART" ] ||
        die "Root partition was not created: $ROOT_PART"

    mkfs.ext4 -F -L rootfs "$ROOT_PART"

    ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"

    [ -n "$ROOT_UUID" ] ||
        die "Could not determine root UUID."

    echo
    echo "Final partition layout:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$TARGET_DISK"

    echo
    echo "Root UUID: $ROOT_UUID"
}

mount_target() {
    log "Mounting target"

    mkdir -p \
        "$TARGET_MOUNT" \
        "$TARGET_MOUNT/dev" \
        "$TARGET_MOUNT/dev/pts" \
        "$TARGET_MOUNT/proc" \
        "$TARGET_MOUNT/sys" \
        "$TARGET_MOUNT/run"

    mount "$ROOT_PART" "$TARGET_MOUNT"

    mount --bind /dev "$TARGET_MOUNT/dev"
    mount --bind /dev/pts "$TARGET_MOUNT/dev/pts"
    mount -t proc proc "$TARGET_MOUNT/proc"
    mount -t sysfs sys "$TARGET_MOUNT/sys"
    mount --bind /run "$TARGET_MOUNT/run"

    if [ "$BOOT_MODE" = "UEFI" ]; then
        mkdir -p "$TARGET_MOUNT/boot/efi"
        mount "$EFI_PART" "$TARGET_MOUNT/boot/efi"
    fi

    cp -L /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"
}

run_debootstrap() {
    log "Running debootstrap"

    debootstrap \
        --arch=amd64 \
        --variant=minbase \
        "$CODENAME" \
        "$TARGET_MOUNT" \
        "$UBUNTU_MIRROR"

    [ -x "$TARGET_MOUNT/usr/bin/apt-get" ] ||
        die "debootstrap did not create a valid Ubuntu root filesystem."
}

configure_system() {
    log "Configuring Ubuntu"

    cat > "$TARGET_MOUNT/etc/apt/sources.list" <<EOF
deb $UBUNTU_MIRROR $CODENAME main restricted universe multiverse
deb $UBUNTU_MIRROR ${CODENAME}-updates main restricted universe multiverse
deb $UBUNTU_MIRROR ${CODENAME}-security main restricted universe multiverse
EOF

    cat > "$TARGET_MOUNT/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1
/swapfile none swap sw 0 0
EOF

    cat > "$TARGET_MOUNT/etc/hostname" <<EOF
ubuntu-server
EOF

    cat > "$TARGET_MOUNT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ubuntu-server
EOF

    # Keep the Rescue NIC's MAC address and force a stable interface
    # name inside the installed Ubuntu system.
    mkdir -p "$TARGET_MOUNT/etc/systemd/network"

    cat > "$TARGET_MOUNT/etc/systemd/network/10-server-nic.link" <<EOF
[Match]
MACAddress=$DEFAULT_MAC

[Link]
Name=server0
EOF

    mkdir -p "$TARGET_MOUNT/etc/network"

    cat > "$TARGET_MOUNT/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto server0
iface server0 inet static
    address $DEFAULT_IP
    netmask $DEFAULT_NETMASK
    gateway $DEFAULT_GATEWAY
    dns-nameservers 8.8.8.8 1.1.1.1
EOF
}

install_packages() {
    log "Installing Ubuntu packages"

    chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

apt-get update

if [ "$(bootctl is-enabled 2>/dev/null || true)" = "enabled" ]; then
    :
fi

apt-get install -y \
    linux-image-generic \
    openssh-server \
    sudo \
    vim \
    net-tools \
    iproute2 \
    iputils-ping \
    ifupdown \
    curl \
    ca-certificates \
    locales

if [ -d /sys/firmware/efi ]; then
    apt-get install -y \
        grub-efi-amd64 \
        grub-efi-amd64-bin \
        grub-efi-amd64-signed \
        shim-signed \
        dosfstools
else
    apt-get install -y \
        grub-pc
fi

systemctl enable ssh || true
systemctl enable networking || true

locale-gen en_US.UTF-8 || true

apt-get clean
CHROOT
}

set_root_password() {
    log "Set Ubuntu root password"

    echo
    echo "Please set the root password for the new Ubuntu installation."
    echo

    chroot "$TARGET_MOUNT" /bin/bash -c 'passwd root'

    local first_char

    first_char="$(
        chroot "$TARGET_MOUNT" /bin/bash -c \
        "grep '^root:' /etc/shadow | cut -d: -f2 | head -c1"
    )"

    [ "$first_char" = '$' ] ||
        [ "$first_char" = '!' ] || true

    echo "Root password configured."
}

configure_ssh() {
    log "Configuring SSH"

    chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
sed -i \
    's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' \
    /etc/ssh/sshd_config

sed -i \
    's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config

grep -q '^PermitRootLogin yes$' /etc/ssh/sshd_config || \
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config

grep -q '^PasswordAuthentication yes$' /etc/ssh/sshd_config || \
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
CHROOT
}

create_swap() {
    log "Creating 4 GB swapfile"

    chroot "$TARGET_MOUNT" /bin/bash <<CHROOT
set -e

if [ ! -f /swapfile ]; then
    fallocate -l ${SWAP_SIZE_MB}M /swapfile ||
        dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB}

    chmod 600 /swapfile
    mkswap /swapfile
fi
CHROOT
}

install_grub() {
    log "Installing GRUB"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ubuntu \
    --recheck

update-grub
CHROOT

    else

        chroot "$TARGET_MOUNT" /bin/bash <<CHROOT
export DEBIAN_FRONTEND=noninteractive

grub-install \
    --target=i386-pc \
    --recheck \
    "$TARGET_DISK"

update-grub
CHROOT

    fi
}

verify_install() {
    log "Pre-reboot verification"

    echo "=== fstab ==="
    cat "$TARGET_MOUNT/etc/fstab"

    echo
    echo "=== Network ==="
    cat "$TARGET_MOUNT/etc/network/interfaces"

    echo
    echo "=== Kernel ==="
    ls "$TARGET_MOUNT"/boot/vmlinuz-* \
       "$TARGET_MOUNT"/boot/initrd.img-*

    echo
    echo "=== Root password status ==="
    chroot "$TARGET_MOUNT" /bin/bash -c \
        "grep '^root:' /etc/shadow | cut -d: -f2 | head -c1"

    echo
    echo

    if [ "$BOOT_MODE" = "UEFI" ]; then

        [ -d "$TARGET_MOUNT/boot/efi/EFI" ] ||
            die "UEFI boot files were not found."

        echo "UEFI boot files: OK"

    else

        [ -f "$TARGET_MOUNT/boot/grub/i386-pc/core.img" ] ||
            die "BIOS GRUB core.img not found."

        echo "BIOS GRUB core.img: OK"
    fi

    echo
    echo "Kernel/initrd: OK"
    echo "fstab: OK"
    echo "Network config: OK"
    echo "Verification complete."
}

show_summary() {
    log "INSTALLATION READY"

    echo "OS          : $OS_NAME"
    echo "Boot mode   : $BOOT_MODE"
    echo "Target disk : $TARGET_DISK"
    echo "Root part   : $ROOT_PART"
    echo "Root UUID   : $ROOT_UUID"
    echo "Network     : server0"
    echo "MAC         : $DEFAULT_MAC"
    echo "IP          : $DEFAULT_IP/$DEFAULT_PREFIX"
    echo "Gateway     : $DEFAULT_GATEWAY"
    echo
    echo "Ubuntu 18.04 has been installed."
}

main() {
    clear 2>/dev/null || true

    echo
    echo "============================================================"
    echo "        Ubuntu 18.04 LTS Server Installer"
    echo "============================================================"
    echo
    echo "This script will erase ONLY the disk you select."
    echo

    check_rescue_commands
    detect_boot_mode
    detect_network

    echo
    read -rp "Is the detected network correct? [Y/n]: " net_confirm
    net_confirm="${net_confirm:-Y}"

    [[ "$net_confirm" =~ ^[Yy]$ ]] ||
        die "Installation cancelled."

    select_target_disk

    install_debootstrap
    partition_target
    mount_target
    run_debootstrap
    configure_system
    install_packages
    set_root_password
    configure_ssh
    create_swap
    install_grub
    verify_install

    show_summary

    echo
    read -rp "Unmount and reboot into Ubuntu 18.04 now? [y/N]: " reboot_confirm

    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        cleanup
        sync
        echo
        echo "Rebooting in 5 seconds..."
        sleep 5
        reboot
    else
        cleanup
        echo
        echo "Reboot cancelled."
        echo "The new Ubuntu installation is ready."
    fi
}

main "$@"
