#!/usr/bin/env bash
# Create the primary user (member of wheel for sudo) and prompt for a
# password. Reads USERNAME from the env exported by bootstrap.sh.
# Idempotent: skips useradd if the user exists, and skips the password
# prompt if a password is already set (passwd -S reports 'P' for set).
set -euo pipefail

if ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$USERNAME"
fi

# Loop until the password is actually set. passwd exits non-zero on
# mismatch / too-simple / etc.; without this loop a single typo aborts
# the whole bootstrap and we have to wipe and start over. The loop
# condition reads the password status (P = password set) so we exit
# the moment passwd succeeds.
while [ "$(passwd -S "$USERNAME" 2>/dev/null | awk '{print $2}')" != "P" ]; do
  passwd "$USERNAME" </dev/tty || echo "Password not set; try again."
done
