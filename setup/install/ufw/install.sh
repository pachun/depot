#!/usr/bin/env bash
# Install and enable the firewall. Default policy: deny all incoming,
# allow all outgoing. Allow entries come from ufw-allows.toml alongside
# this script — each entry must have both `what` and `why` or the
# install fails. Idempotent — safe to re-run.
#
# Dependency note: we explicitly install `go-yq` (mikefarah's Go yq),
# NOT the `yq` package which is the Python yq (kislyuk). The
# `-p toml` flag below is mikefarah-specific syntax — the Python yq
# silently fails on that flag, the loop produces no rules, and ufw
# enables with default-deny-everything. SSH lockout follows. Lesson:
# declare the exact dep we built against, never let the wrong
# implementation slip in via name collision.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo pacman -S --needed --noconfirm ufw go-yq

sudo ufw default deny incoming
sudo ufw default allow outgoing

# Belt-and-suspenders: always allow ssh before parsing the TOML. If
# the TOML somehow ends up wrong (typo, missing entry, parsing error),
# we still don't lock ourselves out of the only way to fix it.
sudo ufw allow ssh

# Read every entry into an array first so we can verify the parse
# returned something. A silent empty result here is exactly the bug
# that caused the SSH lockout, so we refuse to proceed.
mapfile -t entries < <(yq -p toml -r '.allow[] | [.what // "", .why // ""] | @tsv' "$HERE/ufw-allows.toml")
if [ "${#entries[@]}" -eq 0 ]; then
  echo "ufw-allows.toml: parsed zero entries — aborting before we lock SSH out" >&2
  exit 1
fi

for entry in "${entries[@]}"; do
  IFS=$'\t' read -r what why <<< "$entry"
  if [[ -z "$what" || -z "$why" ]]; then
    echo "ufw-allows.toml: each [[allow]] entry needs both 'what' and 'why'" >&2
    exit 1
  fi
  sudo ufw allow "$what"
done

sudo ufw --force enable
sudo systemctl enable --now ufw

# Print the SSH command the user will use to log in from another
# machine, now that we've confirmed SSH is allowed through the firewall.
# ip route get to 1.1.1.1 gives the LAN-facing IP without parsing every
# interface, and stays correct on both wired and WiFi.
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
if [ -n "$IP" ]; then
  echo
  echo "SSH from another machine: ssh $USER@$IP"
  echo
fi
