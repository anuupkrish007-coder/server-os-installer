#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Ubuntu 18.04 LTS Server Installer
#
# Supported rescue environments:
#   - Rocky Linux Rescue 9
#   - GRML Rescue
#
# Target:
#   - Ubuntu 18.04 LTS (Bionic Beaver)
#
# Features:
#   - BIOS and UEFI support
#   - Interactive target disk selection
#   - Automatic network detection
#   - Single ext4 root partition
#   - Swapfile
#   - SSH server
#   - Static IPv4 configuration
#   - GRUB bootloader
#   - Works without dpkg-deb
#
# WARNING:
#   The selected target disk will be COMPLETELY ERASED.
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OS_NAME="Ubuntu 18.04 LTS"
CODENAME="bionic"

UBUNTU_MIRROR="http://old-releases.ubuntu.com/ubuntu"

TARGET_MOUNT="/mnt/target"
WORK_DIR="/tmp/ubuntu-18-installer"

DEBOOTSTRAP_VERSION="1.0.141"
DEBOOTSTRAP_URL="https://deb.debian.org/debian/pool/main/d/debootstrap/debootstrap_${DEBOOTSTRAP_VERSION}_all.deb"

TARGET_DISK=""
ROOT_PART=""
EFI_PART=""

BOOT_MODE=""
DEFAULT_IF=""
DEFAULT_IP=""
DEFAULT_PREFIX=""
DEFAULT_GATEWAY=""
DEFAULT_MAC=""

ROOT_UUID=""
SWAP_SIZE="4G"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    set +e

    for mp in \
        "$TARGET_MOUNT/dev/pts" \
        "$TARGET_MOUNT/dev" \
        "$TARGET_MOUNT/proc" \
        "$TARGET_MOUNT/sys" \
        "$TARGET_MOUNT/run"; do

        if mountpoint -q "$mp" 2>/dev/null; then
            umount -lf "$mp" 2>/dev/null || true
        fi
    done

    if mountpoint -q "$TARGET_MOUNT" 2>/dev/null; then
        umount -lf "$TARGET_MOUNT" 2>/dev/null || true
    fi
}

trap cleanup EXIT

check_commands() {

    log "Checking required rescue commands"

    local cmds=(
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
        parted
        reboot
        sed
        tar
        wipefs
    )

    local missing=()

    for cmd in "${cmds[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        die "Missing commands: ${missing[*]}"
    fi

    if ! command_exists mkfs.ext4; then
        die "mkfs.ext4 is required."
    fi

    if ! command_exists mkfs.fat; then
        echo "WARNING: mkfs.fat not found."
        echo "UEFI installation may require dosfstools."
    fi

    echo "Required commands are available."
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

    log "Detecting network configuration"

    DEFAULT_IF="$(
        ip -4 route show default |
        awk 'NR==1 {print $5}'
    )"

    [ -n "$DEFAULT_IF" ] ||
        die "Could not determine default network interface."

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
        cat "/sys/class/net/$DEFAULT_IF/address"
    )"

    [ -n "$DEFAULT_IP" ] ||
        die "Could not determine IPv4 address."

    [ -n "$DEFAULT_PREFIX" ] ||
        die "Could not determine IPv4 prefix."

    [ -n "$DEFAULT_GATEWAY" ] ||
        die "Could not determine default gateway."

    echo "Interface : $DEFAULT_IF"
    echo "MAC       : $DEFAULT_MAC"
    echo "IP        : $DEFAULT_IP"
    echo "Prefix    : /$DEFAULT_PREFIX"
    echo "Gateway   : $DEFAULT_GATEWAY"
}

select_target_disk() {

    log "Available physical disks"

    lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

    echo
    read -rp "Target disk (example: /dev/sda): " TARGET_DISK

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
    echo "Selected disk:"
    echo
    echo "Device : $TARGET_DISK"
    echo "Size   : $disk_size"
    echo "Model  : $disk_model"
    echo "Serial : $disk_serial"
    echo

    echo "WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED."
    echo

    read -rp "Type WIPE to continue: " confirm

    [ "$confirm" = "WIPE" ] ||
        die "Disk wipe cancelled."

    if lsblk -nr -o MOUNTPOINT "$TARGET_DISK" |
        grep -qE '.+'; then

        die "One or more partitions on $TARGET_DISK are mounted."
    fi
}

install_debootstrap() {

    log "Installing debootstrap"

    if command_exists debootstrap; then
        echo "debootstrap already available."
        debootstrap --version || true
        return
    fi

    mkdir -p "$WORK_DIR"

    local deb="$WORK_DIR/debootstrap.deb"

    echo "Downloading debootstrap:"
    echo "$DEBOOTSTRAP_URL"

    curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        "$DEBOOTSTRAP_URL" \
        -o "$deb" ||
        die "Failed to download debootstrap package."

    rm -rf "$WORK_DIR/debootstrap-extract"
    mkdir -p "$WORK_DIR/debootstrap-extract"

    if command_exists dpkg-deb; then

        echo "Using dpkg-deb for extraction."

        dpkg-deb -x \
            "$deb" \
            "$WORK_DIR/debootstrap-extract"

    else

        echo "dpkg-deb not available."
        echo "Using ar + tar extraction."

        local deb_extract="$WORK_DIR/deb-extract"

        rm -rf "$deb_extract"
        mkdir -p "$deb_extract"

        (
            cd "$deb_extract"

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
                die "Could not find data archive inside debootstrap package."

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
                        die "tar does not support zstd extraction."
                    fi
                    ;;

                *)
                    die "Unsupported data archive: $data_archive"
                    ;;
            esac
        )
    fi

    if [ ! -f \
        "$WORK_DIR/debootstrap-extract/usr/sbin/debootstrap" ]; then

        die "Could not extract debootstrap."
    fi

    rm -rf /usr/local/share/debootstrap
    mkdir -p /usr/local/share

    if [ -d \
        "$WORK_DIR/debootstrap-extract/usr/share/debootstrap" ]; then

        cp -a \
            "$WORK_DIR/debootstrap-extract/usr/share/debootstrap" \
            /usr/local/share/
    fi

    cp \
        "$WORK_DIR/debootstrap-extract/usr/sbin/debootstrap" \
        /usr/local/sbin/debootstrap

    chmod 755 /usr/local/sbin/debootstrap

    debootstrap --version || true

    echo "debootstrap installed successfully."
}

partition_disk() {

    log "Partitioning $TARGET_DISK"

    wipefs -a "$TARGET_DISK"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        echo "Creating GPT partition table."

        parted -s "$TARGET_DISK" \
            mklabel gpt

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

    else

        echo "Creating GPT partition table for BIOS."

        parted -s "$TARGET_DISK" \
            mklabel gpt

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
    fi

    sleep 2

    partprobe "$TARGET_DISK" 2>/dev/null || true

    sleep 2

    echo
    lsblk "$TARGET_DISK"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        [ -b "$EFI_PART" ] ||
            die "EFI partition was not created."

        echo "Formatting EFI partition:"
        mkfs.fat -F32 "$EFI_PART"

    fi

    [ -b "$ROOT_PART" ] ||
        die "Root partition was not created."

    echo "Formatting root partition:"
    mkfs.ext4 -F -L rootfs "$ROOT_PART"

    ROOT_UUID="$(
        blkid -s UUID -o value "$ROOT_PART"
    )"

    [ -n "$ROOT_UUID" ] ||
        die "Could not obtain root filesystem UUID."

    echo
    echo "Root UUID: $ROOT_UUID"
}

mount_target() {

    log "Mounting target filesystem"

    mkdir -p "$TARGET_MOUNT"

    mount "$ROOT_PART" "$TARGET_MOUNT"

    mkdir -p \
        "$TARGET_MOUNT/dev" \
        "$TARGET_MOUNT/dev/pts" \
        "$TARGET_MOUNT/proc" \
        "$TARGET_MOUNT/sys" \
        "$TARGET_MOUNT/run"
}

run_debootstrap() {

    log "Installing Ubuntu 18.04 base system"

    debootstrap \
        --arch=amd64 \
        --variant=minbase \
        "$CODENAME" \
        "$TARGET_MOUNT" \
        "$UBUNTU_MIRROR"
}

configure_target() {

    log "Configuring installed Ubuntu system"

    mount --bind /dev "$TARGET_MOUNT/dev"
    mount --bind /dev/pts "$TARGET_MOUNT/dev/pts"
    mount -t proc proc "$TARGET_MOUNT/proc"
    mount -t sysfs sys "$TARGET_MOUNT/sys"
    mount --bind /run "$TARGET_MOUNT/run"

    cp -L /etc/resolv.conf \
        "$TARGET_MOUNT/etc/resolv.conf"

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

::1 localhost ip6-localhost ip6-loopback
EOF

    mkdir -p "$TARGET_MOUNT/etc/network"

    cat > "$TARGET_MOUNT/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto $DEFAULT_IF
iface $DEFAULT_IF inet static
    address $DEFAULT_IP
    netmask $(python3 - <<PY
import ipaddress
print(ipaddress.IPv4Network("0.0.0.0/$DEFAULT_PREFIX").netmask)
PY
)
    gateway $DEFAULT_GATEWAY
    dns-nameservers 8.8.8.8 1.1.1.1
EOF
}

install_packages() {

    log "Installing required Ubuntu packages"

    chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

apt-get update

apt-get install -y \
    linux-image-generic \
    grub-pc \
    openssh-server \
    ifupdown \
    net-tools \
    iproute2 \
    iputils-ping \
    curl \
    ca-certificates \
    sudo \
    vim \
    bash-completion \
    locales \
    cloud-init

systemctl enable ssh || true
systemctl enable networking || true

echo "root:ChangeMeNow!" | chpasswd

mkdir -p /etc/ssh/sshd_config.d

sed -i \
    's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
    /etc/ssh/sshd_config

sed -i \
    's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config

locale-gen en_US.UTF-8 || true

update-initramfs -c -k all || true

apt-get clean
CHROOT
}

create_swap() {

    log "Creating ${SWAP_SIZE} swapfile"

    chroot "$TARGET_MOUNT" /bin/bash <<CHROOT

if [ ! -f /swapfile ]; then

    fallocate -l $SWAP_SIZE /swapfile ||
        dd if=/dev/zero of=/swapfile bs=1M count=4096

    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

fi

CHROOT
}

install_grub() {

    log "Installing GRUB"

    if [ "$BOOT_MODE" = "UEFI" ]; then

        mkdir -p "$TARGET_MOUNT/boot/efi"

        mount "$EFI_PART" \
            "$TARGET_MOUNT/boot/efi"

        chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ubuntu \
    --recheck
CHROOT

    else

        chroot "$TARGET_MOUNT" /bin/bash <<CHROOT
export DEBIAN_FRONTEND=noninteractive

grub-install \
    --target=i386-pc \
    --recheck \
    "$TARGET_DISK"
CHROOT

    fi

    chroot "$TARGET_MOUNT" /bin/bash <<'CHROOT'
update-grub
CHROOT
}

validate_installation() {

    log "Validating installation"

    [ -f "$TARGET_MOUNT/etc/fstab" ] ||
        die "fstab missing."

    [ -f "$TARGET_MOUNT/etc/network/interfaces" ] ||
        die "Network configuration missing."

    [ -f "$TARGET_MOUNT/boot/vmlinuz-"* ] ||
        die "Kernel image missing."

    [ -f "$TARGET_MOUNT/boot/initrd.img-"* ] ||
        die "Initramfs missing."

    [ -f "$TARGET_MOUNT/boot/grub/grub.cfg" ] ||
        die "GRUB configuration missing."

    [ -f "$TARGET_MOUNT/etc/ssh/sshd_config" ] ||
        die "SSH configuration missing."

    if [ "$BOOT_MODE" = "UEFI" ]; then

        [ -d "$TARGET_MOUNT/boot/efi/EFI" ] ||
            die "UEFI boot files missing."

    else

        [ -f "$TARGET_MOUNT/boot/grub/i386-pc/core.img" ] ||
            die "BIOS GRUB core.img missing."

    fi

    echo "Installation validation passed."
}

show_summary() {

    log "Installation completed"

    echo "OS          : $OS_NAME"
    echo "Boot mode   : $BOOT_MODE"
    echo "Target disk : $TARGET_DISK"
    echo "Root        : $ROOT_PART"
    echo "Root UUID   : $ROOT_UUID"
    echo "Network     : $DEFAULT_IF"
    echo "IP          : $DEFAULT_IP/$DEFAULT_PREFIX"
    echo "Gateway     : $DEFAULT_GATEWAY"
    echo
    echo "SSH root password:"
    echo
    echo "ChangeMeNow!"
    echo
    echo "IMPORTANT: Change the root password after login."
    echo
}

main() {

    clear 2>/dev/null || true

    echo
    echo "============================================================"
    echo "        Ubuntu 18.04 LTS Server Installer"
    echo "============================================================"
    echo
    echo "THIS SCRIPT WILL ERASE THE SELECTED DISK."
    echo

    check_commands

    detect_boot_mode

    detect_network

    select_target_disk

    install_debootstrap

    partition_disk

    mount_target

    run_debootstrap

    configure_target

    install_packages

    create_swap

    install_grub

    validate_installation

    show_summary

    echo
    read -rp "Reboot into Ubuntu 18.04 now? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then

        cleanup

        echo
        echo "Rebooting in 5 seconds..."
        sleep 5

        reboot

    else

        cleanup

        echo
        echo "Reboot cancelled."
        echo "You can reboot manually."
    fi
}

main "$@"
