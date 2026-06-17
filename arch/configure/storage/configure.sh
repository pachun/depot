#!/usr/bin/env bash
# Storage — set up the RAIDZ1 pool that holds the media library,
# plus format and mount the user-supplied SSD as the downloads
# staging tier. Runs after bootstrap, before configure.sh, so every
# depot bind-mount under ~/hdds and ~/downloading lands on the
# right storage automatically.
#
# Disk selection happens in prompts.sh (sourced by install.sh's
# dispatcher up front so the user isn't blocked mid-flight). This
# script consumes those choices via /tmp/depot-storage-choices.env
# and runs unattended.
#
# Pool configuration:
#   - RAIDZ1 (single-parity)
#   - compression=lz4 (cheap, ~3-5% savings on media)
#   - atime=off (no metadata write on every read)
#   - recordsize=1M (good for large media reads; small-file write
#     amplification is acceptable for the config/secrets files that
#     live under ~/hdds/.config — they're tiny and infrequent)
#   - ashift=12 (4K sector alignment; modern drives often misreport
#     512-byte sectors for backwards compat)
#   - Mountpoint: ~/hdds
#   - Weekly scrub via the bundled systemd timer
#   - ZED enabled to log disk events to journal (`journalctl -u zed`).
#     Email alerts need additional SMTP setup and stay outside this
#     script.
#
# Idempotent: if the pool already exists every step short-circuits;
# if prompts.sh didn't write a choice (no disks, or user aborted),
# the matching tier is skipped cleanly.
#
# No -f / --force on zpool create — if any drive has a stray
# signature, the create fails and the user has to wipe it first
# rather than auto-destroying potentially-real data.
set -euo pipefail

POOL_NAME="tank"
MOUNTPOINT="$HOME/hdds"
DOWNLOADING_MOUNT="$HOME/downloading"
CHOICES_ENV="/tmp/depot-storage-choices.env"

SELECTED_HDD_NAMES=()
SELECTED_SSD_NAME=""

if [ -f "$CHOICES_ENV" ]; then
  # shellcheck disable=SC1090
  source "$CHOICES_ENV"
fi

# ============================================================
# HDD pool.
# ============================================================

# Short-circuit if the pool already exists.
if command -v zpool >/dev/null 2>&1 \
   && zpool list "$POOL_NAME" >/dev/null 2>&1; then
  echo "ZFS pool '$POOL_NAME' already exists — skipping pool creation."
elif [ ${#SELECTED_HDD_NAMES[@]} -eq 0 ]; then
  echo "Storage: no HDDs picked at prompt time — skipping pool creation."
else
  # zfs-dkms + zfs-utils were installed during the bootstrap chroot
  # phase (arch/install/095-install-zfs/) so the DKMS module was built
  # against the matching pacstrap'd kernel + headers — no version
  # drift. All we need here is to load the module.
  if ! lsmod | grep -q '^zfs'; then
    sudo modprobe zfs
  fi

  # Resolve each /dev/sdX to a stable /dev/disk/by-id/ path. ZFS
  # stores these in the pool metadata, so a SATA-cable reshuffle or
  # controller re-numbering doesn't confuse the import on next boot.
  # Prefer ata-* / nvme-* paths because they're the most readable.
  disk_ids=()
  for name in "${SELECTED_HDD_NAMES[@]}"; do
    id_path=$(find /dev/disk/by-id/ -maxdepth 1 -lname "*/$name" \
      | grep -E '/(ata|nvme)-' | head -1)
    if [ -z "$id_path" ]; then
      id_path=$(find /dev/disk/by-id/ -maxdepth 1 -lname "*/$name" | head -1)
    fi
    if [ -z "$id_path" ]; then
      echo "No stable by-id path for /dev/$name" >&2
      exit 1
    fi
    disk_ids+=("$id_path")
  done

  echo ""
  echo "Creating RAIDZ1 pool '$POOL_NAME' across:"
  for id in "${disk_ids[@]}"; do
    echo "  $id"
  done

  sudo zpool create \
    -o ashift=12 \
    -O compression=lz4 \
    -O atime=off \
    -O recordsize=1M \
    -O mountpoint="$MOUNTPOINT" \
    "$POOL_NAME" raidz1 "${disk_ids[@]}"

  # Hand the mountpoint to the install user so configure.sh's mkdir
  # calls under ~/hdds don't need sudo.
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

  echo "ZFS pool '$POOL_NAME' created and mounted at $MOUNTPOINT."
fi

# ============================================================
# Downloads staging tier (SSD, ext4).
# Stays separate from the ZFS pool so heavy random-write download
# workloads don't pound the HDDs. ext4 because it's plain and well-
# understood; we don't need ZFS features (snapshots, parity) for a
# transient staging tier where loss just means re-downloading.
# ============================================================

if mountpoint -q "$DOWNLOADING_MOUNT" 2>/dev/null; then
  echo "$DOWNLOADING_MOUNT already mounted — skipping SSD step."
elif [ -z "$SELECTED_SSD_NAME" ]; then
  echo "Storage: no SSD picked at prompt time — skipping downloads tier."
else
  SSD_DEV="/dev/$SELECTED_SSD_NAME"

  # Stable by-id path for fstab — same reason ZFS uses by-id.
  SSD_ID_PATH=$(find /dev/disk/by-id/ -maxdepth 1 -lname "*/$SELECTED_SSD_NAME" \
    | grep -E '/nvme-' | head -1)
  if [ -z "$SSD_ID_PATH" ]; then
    SSD_ID_PATH=$(find /dev/disk/by-id/ -maxdepth 1 -lname "*/$SELECTED_SSD_NAME" | head -1)
  fi

  echo ""
  echo "Formatting $SSD_DEV as ext4 and mounting at $DOWNLOADING_MOUNT"
  echo "  by-id: $SSD_ID_PATH"

  sudo mkfs.ext4 -F -L downloading "$SSD_DEV"

  sudo mkdir -p "$DOWNLOADING_MOUNT"

  FSTAB_LINE="$SSD_ID_PATH  $DOWNLOADING_MOUNT  ext4  defaults,noatime  0  2"
  if ! grep -qF "$SSD_ID_PATH" /etc/fstab; then
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
  fi

  sudo mount "$DOWNLOADING_MOUNT"
  sudo chown "$USER:$USER" "$DOWNLOADING_MOUNT"

  echo "Downloads tier ready at $DOWNLOADING_MOUNT."
fi
