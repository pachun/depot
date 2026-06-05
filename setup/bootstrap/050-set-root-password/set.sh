#!/usr/bin/env bash
# Mirror the primary user's password to root. The point is recovery:
# if you ever lock yourself out of the user account (forgotten password,
# misconfigured sudo, broken shell config) you can log in as root with
# the same password at the TTY and fix things. Without this, recovery
# means booting with init=/bin/bash from the bootloader or attaching
# the live USB again.
#
# Reads the encrypted hash via getent shadow and applies it with
# chpasswd -e, so the plaintext is never re-derived or stored.
# Reads USERNAME from the env exported by bootstrap.sh.
set -euo pipefail

hash=$(getent shadow "$USERNAME" | cut -d: -f2)
case "$hash" in
  ""|"!"*|"*")
    echo "050-set-root-password: $USERNAME has no password set" >&2
    exit 1
    ;;
esac

echo "root:$hash" | chpasswd -e
