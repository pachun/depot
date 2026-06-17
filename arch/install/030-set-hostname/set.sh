#!/usr/bin/env bash
# Set the hostname from $INSTALL_HOSTNAME (prompted by prompts.sh).
# Idempotent — re-runs overwrite to the same value.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/prompts.sh"

echo "$INSTALL_HOSTNAME" > /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $INSTALL_HOSTNAME.localdomain $INSTALL_HOSTNAME
EOF
