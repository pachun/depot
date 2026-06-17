#!/usr/bin/env bash
# Install ZFS (zfs-linux-lts precompiled module + zfs-utils) during
# the bootstrap chroot phase.
#
# Uses zfs-linux-lts: archzfs publishes precompiled modules built
# against each linux-lts release, paired by exact version. The
# package metadata locks the kernel + zfs versions together — pacman
# can't silently let them drift apart.
#
# Repo URL note: the canonical archzfs repo is now at
# github.com/archzfs/archzfs/releases (the historical archzfs.com
# is described as "now stale" by the maintainers and serves older
# builds). The GitHub-hosted repo is what's actually maintained.
#
# Persists the archzfs repo + key into /etc/pacman.conf and
# /etc/pacman.d/gnupg so future `pacman -Syu` cycles can see archzfs
# (necessary for matching zfs-linux-lts updates as linux-lts moves).
#
# Key ID per the archzfs GitHub releases page — pinned here so a key
# rotation isn't a silent supply-chain change.
set -euo pipefail

ARCHZFS_KEY="3A9917BF0DED5C13F69AC68FABEC0A1208037BE9"

pacman-key --recv-keys "$ARCHZFS_KEY"
pacman-key --lsign-key "$ARCHZFS_KEY"

if ! grep -q '^\[archzfs\]' /etc/pacman.conf; then
  tee -a /etc/pacman.conf >/dev/null <<'EOF'

[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF
fi

# -Sy (not -Syu) so we don't yank in a newer kernel mid-install — the
# only repo movement we want here is making archzfs's packages visible
# to the solver. zfs-linux-lts is strictly paired to the exact
# linux-lts version pacstrap just installed.
pacman -Sy --needed --noconfirm zfs-linux-lts zfs-utils
