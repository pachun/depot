#!/usr/bin/env bash
# Install systemd-boot to the EFI partition mounted at /boot, then write
# the loader config and an entry that boots the just-pacstrapped Arch
# install with the root partition referenced by PARTUUID.
#
# Reads PART_ROOT from the env exported by bootstrap.sh — that's the
# /dev/nvme0n1p2 (or similar) path we partitioned and formatted as ext4.
#
# Idempotent: bootctl install is safe to re-run; the loader.conf and
# entry file are overwritten with the same content on every run.
set -euo pipefail

bootctl --esp-path=/boot install

# Look up the PARTUUID for the root partition. This is stable across
# reboots and across cable swaps; using /dev paths would be fragile.
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$PART_ROOT")

cat > /boot/loader/loader.conf <<EOF
default depot.conf
timeout 0
console-mode max
editor no
EOF

cat > /boot/loader/entries/depot.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$ROOT_PARTUUID rw
EOF
