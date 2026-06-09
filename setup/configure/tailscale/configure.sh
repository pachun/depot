#!/usr/bin/env bash
# Install tailscale, enable the daemon, and authenticate this machine
# onto the tailnet. `tailscale up` prints a URL the user clicks on
# another device to sign in — headless-friendly, no local browser
# needed. Idempotent: if `tailscale status` already shows the machine
# logged in and connected, the up command is skipped.
set -euo pipefail

sudo pacman -S --needed --noconfirm tailscale
sudo systemctl enable --now tailscaled.service

if ! sudo tailscale status >/dev/null 2>&1; then
  sudo tailscale up
fi

# Print the tailnet hostname so the user knows the from-anywhere SSH
# address. tailscale status --self --peers=false outputs one line for
# this machine: <IP> <FQDN> <user> <os> <connection-status>.
TAILNET_HOST=$(sudo tailscale status --self --peers=false 2>/dev/null | awk 'NR==1 {print $2}')
TAILNET_IP=$(sudo tailscale ip -4 2>/dev/null | head -1)

if [ -n "$TAILNET_HOST" ]; then
  echo
  echo "Tailscale: ssh $USER@$TAILNET_HOST"
  echo
elif [ -n "$TAILNET_IP" ]; then
  echo
  echo "Tailscale: ssh $USER@$TAILNET_IP"
  echo
fi
