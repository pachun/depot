#!/usr/bin/env bash
# Create the primary user (member of wheel for sudo) with the password
# collected by prompts.sh. Idempotent: skips useradd if the user exists,
# and skips chpasswd if a password is already set (passwd -S reports
# 'P' for set).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/prompts.sh"

if ! id "$INSTALL_USERNAME" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$INSTALL_USERNAME"
fi

if [ "$(passwd -S "$INSTALL_USERNAME" 2>/dev/null | awk '{print $2}')" != "P" ]; then
  echo "$INSTALL_USERNAME:$INSTALL_USER_PASSWORD" | chpasswd
fi
