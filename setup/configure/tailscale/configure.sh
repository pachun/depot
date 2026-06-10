#!/usr/bin/env bash
# Install tailscale, enable the daemon, and authenticate this machine
# onto the tailnet. `tailscale up` prints a URL the user clicks on
# another device to sign in — headless-friendly, no local browser
# needed. Idempotent: if `tailscale status` already shows the machine
# logged in and connected, the up command is skipped.
set -euo pipefail

# jq is used by https-url.sh to parse `tailscale status --json` for
# the tailnet FQDN. Installed alongside tailscale so any feature using
# the tailscale/* helpers gets it for free.
sudo pacman -S --needed --noconfirm tailscale jq
sudo systemctl enable --now tailscaled.service

if ! sudo tailscale status >/dev/null 2>&1; then
  sudo tailscale up
fi

# Tailnet SSH address printed by summary.sh in configure.sh's Phase 3.
