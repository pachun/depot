#!/usr/bin/env bash
# Tear down the ZFS pool and wipe its disks back to a clean slate.
# Use when you want to re-run arch/configure/storage/configure.sh from
# scratch — without this the next install short-circuits because
# the pool already exists.
#
# Safety:
#   - Type-the-phrase confirmation gate before anything destructive.
#   - Reads the disk list from zpool status itself rather than
#     re-deriving it, so you can only wipe the disks the pool was
#     actually using. No globbing /dev/sd[a-d] from memory at 2am.
#   - No -f / --force on zpool destroy; if the pool is in a state
#     where it won't destroy cleanly, the script aborts rather than
#     hiding the problem.
set -euo pipefail

POOL_NAME="tank"

if ! command -v zpool >/dev/null 2>&1; then
  echo "zpool not installed — nothing to do."
  exit 0
fi

if ! zpool list "$POOL_NAME" >/dev/null 2>&1; then
  echo "ZFS pool '$POOL_NAME' doesn't exist — nothing to do."
  echo "(If you want to wipe ZFS signatures off disks that aren't in"
  echo " an active pool, run wipefs manually on the specific devices.)"
  exit 0
fi

# zpool status -P prints fully qualified /dev/ paths for every disk
# in the pool. Grab those — they're already in the by-id form ZFS
# was tracking.
mapfile -t POOL_DISKS < <(
  sudo zpool status -P "$POOL_NAME" \
    | awk '$1 ~ /^\/dev\// { print $1 }' \
    | sort -u
)

if [ ${#POOL_DISKS[@]} -eq 0 ]; then
  echo "ERROR: couldn't read any disk paths from 'zpool status -P $POOL_NAME'." >&2
  echo "       Run it manually and tear the pool down by hand." >&2
  exit 1
fi

echo ""
echo "About to DESTROY ZFS pool '$POOL_NAME' and wipe its disks:"
for d in "${POOL_DISKS[@]}"; do
  echo "  $d"
done
echo ""
echo "ALL DATA in the pool will be PERMANENTLY LOST."
echo ""
read -r -p "Type 'destroy pool' to confirm: " confirmation
if [ "$confirmation" != "destroy pool" ]; then
  echo "Aborted."
  exit 1
fi

sudo zpool destroy "$POOL_NAME"

# Wipe ZFS labels and any other filesystem signatures. Without this,
# the next 'zpool create' can refuse because of residual labels.
for d in "${POOL_DISKS[@]}"; do
  # Resolve the by-id symlink to the actual /dev/sdX so wipefs
  # operates on the underlying device, not the symlink.
  resolved=$(readlink -f "$d")
  echo "wiping $resolved"
  sudo wipefs -a "$resolved" >/dev/null
done

echo ""
echo "Pool destroyed and disks wiped. The next run of"
echo "./arch/configure.sh will recreate the pool from scratch."
