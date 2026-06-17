#!/usr/bin/env bash
# Storage — set up the RAIDZ1 pool that holds the media library.
# Runs after bootstrap, before configure.sh, so every depot bind-
# mount under ~/library lands on redundant storage automatically.
#
# Lists all rotational disks, lets the operator pick which ones go
# in the pool (minimum 3 for RAIDZ1). No fixed disk count.
#
# Pool configuration:
#   - RAIDZ1 (single-parity)
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
# Idempotent: if the pool already exists every step short-circuits;
# if there are no rotational disks at all (e.g., the Framework dev
# box), skip cleanly.
#
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

# Internal SATA-attached spinning disks only. ROTA alone is
# unreliable (USB-to-SATA bridges sometimes pass the rotational bit
# through incorrectly — a flash USB can report ROTA=1), so combining
# with TRAN=sata gates the picker on bus type too.
mapfile -t HDD_NAMES < <(
  lsblk -dno NAME,TYPE,ROTA,TRAN | awk '$2 == "disk" && $3 == "1" && $4 == "sata" { print $1 }'
)

if [ ${#HDD_NAMES[@]} -eq 0 ]; then
  echo "No spinning disks found — skipping pool creation."
  exit 0
fi

echo ""
echo "Spinning disks:"
i=1
for name in "${HDD_NAMES[@]}"; do
  size=$(lsblk -dno SIZE "/dev/$name")
  model=$(lsblk -dno MODEL "/dev/$name" | tr -s ' ')
  serial=$(lsblk -dno SERIAL "/dev/$name")
  rota=$(lsblk -dno ROTA "/dev/$name")
  tran=$(lsblk -dno TRAN "/dev/$name")
  printf "  %d) %-6s %-7s %-32s %-22s rota=%s tran=%s\n" \
    "$i" "$name" "$size" "$model" "$serial" "$rota" "$tran"
  i=$((i+1))
done

echo ""
read -r -p "Pick disks for the pool (space- or comma-separated indices): " selection
selection=$(echo "$selection" | tr ',' ' ')

SELECTED_NAMES=()
for idx in $selection; do
  if [[ ! "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt ${#HDD_NAMES[@]} ]; then
    echo "Invalid index: $idx" >&2
    exit 1
  fi
  SELECTED_NAMES+=("${HDD_NAMES[$((idx-1))]}")
done

if [ ${#SELECTED_NAMES[@]} -eq 0 ]; then
  echo "No disks picked. Skipping pool creation."
  exit 0
fi

if [ ${#SELECTED_NAMES[@]} -lt 3 ]; then
  echo "RAIDZ1 needs at least 3 disks. Selected: ${#SELECTED_NAMES[@]}." >&2
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
# Prefer ata-* / nvme-* paths because they're the most readable.
disk_ids=()
for name in "${SELECTED_NAMES[@]}"; do
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
echo "About to create RAIDZ1 pool '$POOL_NAME' across:"
for name in "${SELECTED_NAMES[@]}"; do
  size=$(lsblk -dno SIZE "/dev/$name")
  echo "  /dev/$name   ($size)"
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
