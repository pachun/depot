#!/usr/bin/env bash
# Install and enable the firewall. Default policy: deny all incoming,
# allow all outgoing. Allow entries come from ufw-allows.toml alongside
# this script — each entry must have both `what` and `why` or the
# install fails. Idempotent — safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo pacman -S --needed --noconfirm ufw yq

sudo ufw default deny incoming
sudo ufw default allow outgoing

while IFS=$'\t' read -r what why; do
  if [[ -z "$what" || -z "$why" ]]; then
    echo "ufw-allows.toml: each [[allow]] entry needs both 'what' and 'why'" >&2
    exit 1
  fi
  sudo ufw allow "$what"
done < <(yq -p toml -r '.allow[] | [.what // "", .why // ""] | @tsv' "$HERE/ufw-allows.toml")

sudo ufw --force enable
sudo systemctl enable --now ufw
