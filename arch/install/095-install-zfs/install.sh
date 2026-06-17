#!/usr/bin/env bash
# Install ZFS (zfs-dkms + zfs-utils) during the bootstrap chroot phase
# so the DKMS module gets built against the kernel + headers that
# pacstrap just installed — no version drift possible because nothing
# has been refreshed since pacstrap.
#
# Doing this in the chroot is the fix for the "modprobe: FATAL: Module
# zfs not found" failure that hits if storage/configure.sh tries to
# install zfs later: by then, `pacman -Sy` would refresh the package
# database and pull a newer linux-headers than the running kernel was
# pacstrap'd with, so DKMS would build for the new headers and the
# running kernel wouldn't find a matching module.
#
# Persists the archzfs repo + key into /etc/pacman.conf and
# /etc/pacman.d/gnupg so future `pacman -Syu` on the running system
# can also see archzfs (necessary for kernel upgrades — DKMS will
# rebuild the module against the new headers from this same repo).
#
# Key ID from https://github.com/archzfs/archzfs/wiki — pinned here so
# a key rotation isn't a silent supply-chain change.
set -euo pipefail

ARCHZFS_KEY="DDF7DB817396A49B2A2723F7403BD972F75D9D76"

pacman-key --recv-keys "$ARCHZFS_KEY"
pacman-key --lsign-key "$ARCHZFS_KEY"

if ! grep -q '^\[archzfs\]' /etc/pacman.conf; then
  tee -a /etc/pacman.conf >/dev/null <<'EOF'

[archzfs]
Server = https://archzfs.com/$repo/$arch
EOF
fi

# -Sy (not -Syu) so we don't yank in a newer kernel mid-install — the
# only repo movement we want here is making archzfs's packages visible
# to the solver. zfs-dkms's only kernel-side dep is `linux-headers`
# (any version), which pacstrap just installed, so the solver won't
# touch linux or linux-headers.
pacman -Sy --needed --noconfirm zfs-dkms zfs-utils
