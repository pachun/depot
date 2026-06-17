#!/usr/bin/env bash
# Storage — set up the RAIDZ1 pool that holds the media library.
# Runs after bootstrap, before configure.sh, so every depot bind-
# mount under ~/library lands on redundant storage automatically.
#
# Configuration:
#   - 4 disks, RAIDZ1 (single-parity), ~84 TB usable across 4×28 TB.
#   - compression=lz4 (cheap, ~3-5% savings on media)
#   - atime=off (no metadata write on every read)
#   - recordsize=1M (good for large media reads; small-file write
#     amplification is acceptable for the config/secrets files that
#     live under ~/library/.config — they're tiny and infrequent)
#   - ashift=12 (4K sector alignment; modern drives often misreport
#     512-byte sectors for backwards compat)
#   - Mountpoint: ~/library
#   - Weekly scrub via the bundled systemd timer
#   - ZED enabled to log disk events to journal (`journalctl -u zed`).
#     Email alerts need additional SMTP setup and stay outside this
#     script.
#
# Idempotent on every layer: if the pool already exists every step
# short-circuits; if the box doesn't have exactly 4 non-boot disks
# (e.g., the Framework dev box), skip cleanly.
#
# Safety: pool creation is gated on the user typing an exact phrase.
# No -f / --force on zpool create — if any drive has a stray
# signature, the create fails and the user has to wipe it first
# rather than auto-destroying potentially-real data.
set -euo pipefail

POOL_NAME="tank"
MOUNTPOINT="$HOME/library"

# Short-circuit if the pool already exists and ZFS knows about it.
# `zpool list` exits 0 when the pool is present, non-zero otherwise.
if command -v zpool >/dev/null 2>&1 \
   && zpool list "$POOL_NAME" >/dev/null 2>&1; then
  echo "ZFS pool '$POOL_NAME' already exists — skipping storage setup."
  exit 0
fi

# Disk detection: find every whole disk that isn't the boot disk.
# pkname maps a partition back to its parent disk; if /dev/nvme0n1p2
# is mounted at /, the boot disk is nvme0n1 and the script ignores
# it.
BOOT_PART=$(findmnt -no SOURCE /)
BOOT_DISK=$(lsblk -dno pkname "$BOOT_PART" 2>/dev/null || true)
if [ -z "$BOOT_DISK" ]; then
  BOOT_DISK=$(echo "$BOOT_PART" | sed -E 's@^/dev/@@; s/p?[0-9]+$//')
fi

mapfile -t CANDIDATES < <(
  lsblk -dno NAME,TYPE,SIZE \
    | awk -v boot="$BOOT_DISK" '$2 == "disk" && $1 != boot { print $1 " " $3 }'
)

CANDIDATE_COUNT=${#CANDIDATES[@]}

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "storage skipped — no non-boot disks present (likely a dev box)."
  exit 0
fi

if [ "$CANDIDATE_COUNT" -ne 4 ]; then
  echo "ERROR: storage expects exactly 4 non-boot disks for a RAIDZ1" >&2
  echo "       pool. Found $CANDIDATE_COUNT:" >&2
  for c in "${CANDIDATES[@]}"; do
    echo "         $c" >&2
  done
  echo "       Boot disk: $BOOT_DISK" >&2
  echo "       Adjust install/storage/install.sh or fix hardware before" >&2
  echo "       re-running." >&2
  exit 1
fi

# Install the archzfs repo + zfs-dkms + zfs-utils. zfs is out of the
# official Arch repos because of the CDDL licensing situation; the
# archzfs community repo packages it. Key ID from
# https://github.com/archzfs/archzfs/wiki — pinned here so a key
# rotation isn't a silent supply-chain change.
if ! command -v zpool >/dev/null 2>&1; then
  ARCHZFS_KEY="DDF7DB817396A49B2A2723F7403BD972F75D9D76"
  sudo pacman-key --recv-keys "$ARCHZFS_KEY"
  sudo pacman-key --lsign-key "$ARCHZFS_KEY"

  if ! grep -q '^\[archzfs\]' /etc/pacman.conf; then
    sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

[archzfs]
Server = https://archzfs.com/$repo/$arch
EOF
  fi

  sudo pacman -Sy --needed --noconfirm \
    linux-headers zfs-dkms zfs-utils

  # Load the kernel module so zpool commands work this session
  # without a reboot.
  sudo modprobe zfs
fi

# Resolve each /dev/sdX to a stable /dev/disk/by-id/ path. ZFS
# stores these in the pool metadata, so a SATA-cable reshuffle or
# controller re-numbering doesn't confuse the import on next boot.
# Prefer ata-* / nvme-* paths over scsi-* / wwn-* because they're
# the most human-readable.
disk_ids=()
for entry in "${CANDIDATES[@]}"; do
  name=${entry%% *}
  id_path=$(find /dev/disk/by-id/ -maxdepth 1 -lname "*/$name" \
    | grep -E '/(ata|nvme)-' | head -1)
  if [ -z "$id_path" ]; then
    id_path=$(find /dev/disk/by-id/ -maxdepth 1 -lname "*/$name" | head -1)
  fi
  if [ -z "$id_path" ]; then
    echo "ERROR: no stable by-id path for /dev/$name" >&2
    exit 1
  fi
  disk_ids+=("$id_path")
done

# The big scary confirmation. Type the phrase or no pool gets made.
echo ""
echo "About to create RAIDZ1 pool '$POOL_NAME' across:"
for entry in "${CANDIDATES[@]}"; do
  echo "  /dev/${entry%% *}   (${entry#* })"
done
echo ""
echo "Stable by-id paths (what ZFS will store):"
for id in "${disk_ids[@]}"; do
  echo "  $id"
done
echo ""
echo "ALL DATA on these disks will be DESTROYED."
echo "The pool will mount at $MOUNTPOINT."
echo ""
read -r -p "Type 'destroy and create pool' to confirm: " confirmation
if [ "$confirmation" != "destroy and create pool" ]; then
  echo "Aborted."
  exit 1
fi

sudo zpool create \
  -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O recordsize=1M \
  -O mountpoint="$MOUNTPOINT" \
  "$POOL_NAME" raidz1 "${disk_ids[@]}"

# Hand the mountpoint to the install user so configure.sh's mkdir
# calls under ~/library don't need sudo.
sudo chown "$USER:$USER" "$MOUNTPOINT"

# Auto-import + mount the pool on every boot.
sudo systemctl enable --now zfs-import-cache.service
sudo systemctl enable --now zfs-mount.service
sudo systemctl enable zfs.target

# Weekly scrub keeps bit-rot detection running on a schedule. The
# bundled timer is parameterized per-pool name.
sudo systemctl enable --now "zfs-scrub-weekly@${POOL_NAME}.timer"

# ZED — ZFS Event Daemon. Default config logs every disk event
# (faulted drive, scrub completed, resilver done, etc.) to the
# system journal. View with `journalctl -u zfs-zed`. Setting up
# email alerts is a follow-up step outside this script.
sudo systemctl enable --now zfs-zed.service

echo ""
echo "ZFS pool '$POOL_NAME' created and mounted at $MOUNTPOINT."
echo "Verify with:  zpool status $POOL_NAME"
