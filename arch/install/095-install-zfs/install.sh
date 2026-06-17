#!/usr/bin/env bash
# Install ZFS (zfs-linux-lts precompiled module + zfs-utils) during
# the bootstrap chroot phase.
#
# Uses zfs-linux-lts (not zfs-dkms) because OpenZFS releases lag
# upstream kernel releases by months — DKMS-building against a kernel
# ZFS hasn't caught up to fails with "Cannot build against kernel
# version X. The maximum supported kernel version is Y." This bit us
# even on linux-lts: by mid-2026 LTS had moved to 6.18, past ZFS's
# 6.15 ceiling.
#
# zfs-linux-lts dodges this entirely: archzfs builds the module
# against each linux-lts release as they ship it, and the package
# strictly depends on the exact linux-lts version it was compiled
# against. pacman can never let kernel and zfs drift apart — a
# `pacman -Syu` that would update one without the other just refuses
# until both are buildable.
#
# Persists the archzfs repo + key into /etc/pacman.conf and
# /etc/pacman.d/gnupg so future `pacman -Syu` on the running system
# can also see archzfs (necessary for getting matching zfs-linux-lts
# updates as linux-lts moves).
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
# to the solver. zfs-linux-lts has a strict dep on the exact linux-lts
# version pacstrap just installed, so the solver pulls the matching
# precompiled module.
pacman -Sy --needed --noconfirm zfs-linux-lts zfs-utils
