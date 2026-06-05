#!/usr/bin/env bash
# depot bootstrap. Run from the live Arch ISO after cloning the repo.
# Does the full install (partition the OS NVMe, pacstrap base, etc.) and
# then iterates the configure steps under bootstrap/ inside arch-chroot.
# Ends by running install.sh and rebooting.
#
# SATA drives are explicitly refused as install targets — the NAS's 4
# data HDDs are SATA and the OS drive is NVMe; this guard makes it
# impossible to wipe a data drive by mispicking at the confirmation
# prompt.
set -euo pipefail
shopt -s nullglob

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "bootstrap.sh must run as root" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ============================================================
# Prompts up front. Everything else runs unattended.
# ============================================================

read -rp "username: " USERNAME </dev/tty
read -rp "hostname: " HOSTNAME </dev/tty
export USERNAME HOSTNAME

# ============================================================
# Pick OS drive. Auto-detects NVMe; refuses SATA so the NAS's data
# HDDs can't be wiped by mispick.
# ============================================================

echo
echo "Scanning block devices..."
mapfile -t nvmes < <(lsblk -d -p -n -o NAME,TRAN | awk '$2 == "nvme" {print $1}')
mapfile -t satas < <(lsblk -d -p -n -o NAME,TRAN | awk '$2 == "sata" {print $1}')

if [ "${#nvmes[@]}" -eq 0 ]; then
  echo "No NVMe drive found. Aborting." >&2
  exit 1
fi

echo
echo "NVMe device(s) — candidates for the OS drive:"
for d in "${nvmes[@]}"; do
  size=$(lsblk -d -n -o SIZE "$d")
  model=$(lsblk -d -n -o MODEL "$d" | sed 's/  *$//')
  echo "  $d  ${size}  ${model}"
done

if [ "${#satas[@]}" -gt 0 ]; then
  echo
  echo "SATA device(s) — WILL NOT be touched (data drives, refused as targets):"
  for d in "${satas[@]}"; do
    size=$(lsblk -d -n -o SIZE "$d")
    model=$(lsblk -d -n -o MODEL "$d" | sed 's/  *$//')
    echo "  $d  ${size}  ${model}"
  done
fi

if [ "${#nvmes[@]}" -eq 1 ]; then
  TARGET="${nvmes[0]}"
else
  echo
  echo "Multiple NVMe drives found. Pick by index:"
  for i in "${!nvmes[@]}"; do
    echo "  $i: ${nvmes[$i]}"
  done
  read -rp "Index: " idx </dev/tty
  TARGET="${nvmes[$idx]}"
fi

# Belt-and-suspenders SATA refusal.
case "$TARGET" in
  /dev/sd*)
    echo "Refusing to install on SATA target $TARGET. NVMe only." >&2
    exit 1
    ;;
esac

echo
echo "=========================================================="
echo "  WILL WIPE AND INSTALL ARCH ON: $TARGET"
echo "  Every byte on this device will be destroyed."
echo "=========================================================="
read -rp "Type 'yes' to continue: " confirm </dev/tty
if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 1
fi

# ============================================================
# Verify UEFI boot mode. We install systemd-boot, which is UEFI-only.
# ============================================================

if [ ! -d /sys/firmware/efi/efivars ]; then
  echo "Not booted in UEFI mode. Aborting." >&2
  echo "Reboot the live USB selecting the UEFI entry, then retry." >&2
  exit 1
fi

# ============================================================
# Time sync — pacstrap and key-signature checks fail if the clock is
# wildly off, which is common on fresh boots.
# ============================================================

timedatectl set-ntp true

# ============================================================
# Partition: EFI (512MB) + root (rest). GPT label.
# ============================================================

echo
echo "Partitioning $TARGET..."
parted -s "$TARGET" mklabel gpt
parted -s "$TARGET" mkpart EFI fat32 1MiB 513MiB
parted -s "$TARGET" set 1 esp on
parted -s "$TARGET" mkpart root ext4 513MiB 100%

# NVMe partitions use a 'p<N>' suffix (e.g. /dev/nvme0n1p1).
PART_EFI="${TARGET}p1"
PART_ROOT="${TARGET}p2"

partprobe "$TARGET"
sleep 2

# ============================================================
# Format.
# ============================================================

echo "Formatting partitions..."
mkfs.fat -F 32 -n EFI "$PART_EFI"
mkfs.ext4 -F -L root "$PART_ROOT"

# ============================================================
# Mount root at /mnt and EFI at /mnt/boot.
# ============================================================

echo "Mounting..."
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_EFI" /mnt/boot

# ============================================================
# Pacstrap base packages. Includes networkmanager + openssh + sudo
# so the configure phase has them available to enable.
# ============================================================

echo
echo "Installing base packages (pacstrap)..."
pacstrap -K /mnt base linux linux-firmware vim git networkmanager openssh sudo

# ============================================================
# fstab.
# ============================================================

genfstab -U /mnt >> /mnt/etc/fstab

# ============================================================
# Make this repo reachable from inside the chroot, so the chroot can
# iterate bootstrap/*/. Bind-mount, unmount after.
# ============================================================

mkdir -p /mnt/depot-installer
mount --bind "$ROOT" /mnt/depot-installer

# ============================================================
# Configure phase: iterate bootstrap/*/ inside the chroot. Same shape
# as orchard's bootstrap loop.
# ============================================================

echo
echo "Configuring new system..."
arch-chroot /mnt env USERNAME="$USERNAME" HOSTNAME="$HOSTNAME" PART_ROOT="$PART_ROOT" bash <<'EOF'
set -euo pipefail
shopt -s nullglob
for d in /depot-installer/setup/bootstrap/*/; do
  for script in "$d"*.sh; do
    bash "$script"
  done
done
EOF

# ============================================================
# Unmount bind. (Step 100 copies depot into the user's home, so the
# repo doesn't disappear when we unmount.)
# ============================================================

umount /mnt/depot-installer
rmdir /mnt/depot-installer

# ============================================================
# Run install.sh as the user, inside chroot.
# ============================================================

echo
echo "Running install.sh as $USERNAME inside chroot..."
arch-chroot /mnt sudo -u "$USERNAME" -H bash "/home/$USERNAME/code/depot/setup/install.sh"

# ============================================================
# Finalize.
# ============================================================

umount -R /mnt
echo
echo "Bootstrap complete. Rebooting in 5 seconds..."
sleep 5
reboot
