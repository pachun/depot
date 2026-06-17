#!/usr/bin/env bash
# Storage prompts — collects every interactive choice the storage step
# needs up front (HDD picker + pool-create confirmation, SSD picker +
# format-SSD confirmation) so install.sh can run unattended.
#
# Sourced (not executed) by setup/install.sh's Phase 1. Writes the
# selections to /tmp/depot-storage-choices.env; install.sh sources
# that file and proceeds non-interactively. If the user aborts any
# confirmation, the choices file is not written and install.sh
# short-circuits to a no-op for the corresponding tier.
#
# Idempotent: if the pool already exists, no prompts fire. If the
# downloads mount is already up, the SSD prompts are skipped but the
# HDD prompts (above) still run if the pool itself doesn't exist.

CHOICES_ENV="/tmp/depot-storage-choices.env"
POOL_NAME="tank"
DOWNLOADING_MOUNT="$HOME/downloading"

# Remove any prior choices file so a partial/aborted run doesn't leak
# decisions into a later install.sh.
rm -f "$CHOICES_ENV"

_storage_pool_exists() {
  command -v zpool >/dev/null 2>&1 && zpool list "$POOL_NAME" >/dev/null 2>&1
}

# ---- HDD picker + pool-create confirmation ----

if _storage_pool_exists; then
  : # Pool already up — skip the HDD prompts entirely.
else
  mapfile -t _STORAGE_HDD_NAMES < <(
    lsblk -dno NAME,TYPE,ROTA,TRAN \
      | awk '$2 == "disk" && $3 == "1" && $4 == "sata" { print $1 }'
  )

  if [ ${#_STORAGE_HDD_NAMES[@]} -eq 0 ]; then
    # Dev box (no spinning disks). install.sh will see this and skip.
    echo "Storage: no spinning disks — pool creation will be skipped."
  else
    echo ""
    echo "Spinning disks:"
    _i=1
    for _name in "${_STORAGE_HDD_NAMES[@]}"; do
      _size=$(lsblk -dno SIZE "/dev/$_name")
      _model=$(lsblk -dno MODEL "/dev/$_name" | tr -s ' ')
      _serial=$(lsblk -dno SERIAL "/dev/$_name")
      _rota=$(lsblk -dno ROTA "/dev/$_name")
      _tran=$(lsblk -dno TRAN "/dev/$_name")
      printf "  %d) %-6s %-7s %-32s %-22s rota=%s tran=%s\n" \
        "$_i" "$_name" "$_size" "$_model" "$_serial" "$_rota" "$_tran"
      _i=$((_i+1))
    done

    echo ""
    read -r -p "Pick disks for the pool (space- or comma-separated indices): " _selection
    _selection=$(echo "$_selection" | tr ',' ' ')

    _STORAGE_SELECTED_HDDS=()
    _picker_ok=1
    for _idx in $_selection; do
      if [[ ! "$_idx" =~ ^[0-9]+$ ]] || [ "$_idx" -lt 1 ] || [ "$_idx" -gt ${#_STORAGE_HDD_NAMES[@]} ]; then
        echo "Invalid index: $_idx — skipping pool creation." >&2
        _picker_ok=0
        break
      fi
      _STORAGE_SELECTED_HDDS+=("${_STORAGE_HDD_NAMES[$((_idx-1))]}")
    done

    if [ "$_picker_ok" = "1" ] && [ ${#_STORAGE_SELECTED_HDDS[@]} -lt 3 ]; then
      echo "RAIDZ1 needs at least 3 disks. Selected: ${#_STORAGE_SELECTED_HDDS[@]}. Skipping pool creation."
      _picker_ok=0
    fi

    if [ "$_picker_ok" = "1" ]; then
      echo ""
      echo "About to create RAIDZ1 pool '$POOL_NAME' across:"
      for _name in "${_STORAGE_SELECTED_HDDS[@]}"; do
        _size=$(lsblk -dno SIZE "/dev/$_name")
        echo "  /dev/$_name   ($_size)"
      done
      echo "ALL DATA on these disks will be DESTROYED."
      echo ""
      read -r -p "Type 'destroy and create pool' to confirm: " _confirmation
      if [ "$_confirmation" = "destroy and create pool" ]; then
        printf 'SELECTED_HDD_NAMES=(\n' >> "$CHOICES_ENV"
        for _name in "${_STORAGE_SELECTED_HDDS[@]}"; do
          printf '  %q\n' "$_name" >> "$CHOICES_ENV"
        done
        printf ')\n' >> "$CHOICES_ENV"
      else
        echo "Aborted — pool creation will be skipped."
      fi
    fi
  fi
fi

# ---- SSD picker + format-SSD confirmation ----

if mountpoint -q "$DOWNLOADING_MOUNT" 2>/dev/null; then
  : # Already mounted — install.sh will short-circuit.
else
  _BOOT_PART=$(findmnt -no SOURCE / || true)
  _BOOT_DISK=$(lsblk -dno pkname "$_BOOT_PART" 2>/dev/null || true)

  mapfile -t _STORAGE_SSD_CANDIDATES < <(
    lsblk -dno NAME,TYPE,ROTA,TRAN \
      | awk '$2 == "disk" && $3 == "0" && $4 == "nvme" { print $1 }'
  )

  _STORAGE_SSD_NAMES=()
  for _name in "${_STORAGE_SSD_CANDIDATES[@]}"; do
    if [ "$_name" != "$_BOOT_DISK" ]; then
      _STORAGE_SSD_NAMES+=("$_name")
    fi
  done

  if [ ${#_STORAGE_SSD_NAMES[@]} -eq 0 ]; then
    echo "Storage: no non-boot NVMe — downloads tier will be skipped."
  else
    echo ""
    echo "Non-boot NVMe drives:"
    _i=1
    for _name in "${_STORAGE_SSD_NAMES[@]}"; do
      _size=$(lsblk -dno SIZE "/dev/$_name")
      _model=$(lsblk -dno MODEL "/dev/$_name" | tr -s ' ')
      _serial=$(lsblk -dno SERIAL "/dev/$_name")
      printf "  %d) %-8s %-7s %-32s %s\n" \
        "$_i" "$_name" "$_size" "$_model" "$_serial"
      _i=$((_i+1))
    done

    echo ""
    read -r -p "Pick the SSD to use for downloading (single index): " _ssd_idx

    if [[ ! "$_ssd_idx" =~ ^[0-9]+$ ]] || [ "$_ssd_idx" -lt 1 ] || [ "$_ssd_idx" -gt ${#_STORAGE_SSD_NAMES[@]} ]; then
      echo "Invalid index: $_ssd_idx — downloads tier will be skipped." >&2
    else
      _STORAGE_SELECTED_SSD="${_STORAGE_SSD_NAMES[$((_ssd_idx-1))]}"
      _size=$(lsblk -dno SIZE "/dev/$_STORAGE_SELECTED_SSD")
      echo ""
      echo "About to FORMAT /dev/$_STORAGE_SELECTED_SSD ($_size) as ext4"
      echo "and mount at $DOWNLOADING_MOUNT. ALL DATA on it will be DESTROYED."
      echo ""
      read -r -p "Type 'format ssd' to confirm: " _confirmation
      if [ "$_confirmation" = "format ssd" ]; then
        printf 'SELECTED_SSD_NAME=%q\n' "$_STORAGE_SELECTED_SSD" >> "$CHOICES_ENV"
      else
        echo "Aborted — downloads tier will be skipped."
      fi
    fi
  fi
fi
