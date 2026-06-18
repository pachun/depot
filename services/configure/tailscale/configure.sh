#!/usr/bin/env bash
# Install tailscale, enable the daemon, and authenticate this machine
# onto the tailnet. If prompts.sh collected an auth key, log in
# non-interactively via `tailscale up --auth-key=...` so the install can
# run fully unattended. Without a key, fall back to interactive `tailscale
# up`, which prints a URL the user clicks on another device to sign in —
# headless-friendly, no local browser needed, but the URL expires in a
# few minutes and the install blocks until it's clicked.
# Idempotent: if `tailscale status` already shows the machine logged in
# and connected, the up command is skipped.
set -euo pipefail

# jq is used by https-url.sh to parse `tailscale status --json` for
# the tailnet FQDN. Installed alongside tailscale so any feature using
# the tailscale/* helpers gets it for free.
sudo pacman -S --needed --noconfirm tailscale jq
sudo systemctl enable --now tailscaled.service

# Re-source the env file in case configure.sh was invoked directly
# (not via the dispatcher's Phase 1). The dispatcher already exports
# TAILSCALE_AUTH_KEY for us, so this is just a defensive re-read.
TS_ENV="$HOME/hdds/.config/depot/tailscale.env"
# shellcheck disable=SC1090
[ -f "$TS_ENV" ] && source "$TS_ENV"

if ! sudo tailscale status >/dev/null 2>&1; then
  if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    sudo tailscale up --auth-key="$TAILSCALE_AUTH_KEY"
  else
    sudo tailscale up
  fi
fi

# Tailnet SSH address printed by summary.sh in configure.sh's Phase 3.
