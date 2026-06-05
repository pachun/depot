#!/usr/bin/env bash
# Set the hostname from the HOSTNAME env var that bootstrap.sh prompted
# for and exported. Idempotent — re-runs overwrite to the same value.
set -euo pipefail

echo "$HOSTNAME" > /etc/hostname

# /etc/hosts entry for the loopback hostname resolution.
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF
