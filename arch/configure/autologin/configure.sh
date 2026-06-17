#!/usr/bin/env bash
# Auto-login the install user on tty1 so an unattended reboot (UPS
# event, power blip, kernel update) brings the box all the way back up
# without needing a keyboard plugged in to type a password. The
# machine lives in a laundry room with no peripherals attached; the
# real security boundary is the LAN + tailscale, not the local TTY
# prompt.
#
# Service-level recovery is already handled by every docker-compose
# in services/configure/*/docker-compose.yml using `restart:
# unless-stopped`. Docker itself starts on boot via its systemd unit.
# All this script adds is the missing "skip the TTY login" link.
#
# Override file is a systemd drop-in for getty@tty1.service, so a
# pacman -Syu that updates systemd doesn't blow it away. Idempotent —
# rewriting the same content + reloading daemon is a no-op.
set -euo pipefail

OVERRIDE_DIR=/etc/systemd/system/getty@tty1.service.d
OVERRIDE_FILE="$OVERRIDE_DIR/autologin.conf"

# Build the desired content. The empty ExecStart= first line resets
# the unit's ExecStart so our --autologin replacement doesn't stack
# with the upstream one (systemd would otherwise refuse the unit at
# reload).
DESIRED=$(cat <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF
)

CURRENT=""
[ -f "$OVERRIDE_FILE" ] && CURRENT=$(sudo cat "$OVERRIDE_FILE")

if [ "$CURRENT" = "$DESIRED" ]; then
  exit 0
fi

sudo mkdir -p "$OVERRIDE_DIR"
echo "$DESIRED" | sudo tee "$OVERRIDE_FILE" >/dev/null

sudo systemctl daemon-reload
# Don't restart getty@tty1 mid-install — would kick the user off the
# console if they happen to be on it. Next reboot picks it up; SSH
# sessions are unaffected either way.
