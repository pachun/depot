#!/usr/bin/env bash
# Temp admin password is sourced from container logs each time —
# linuxserver/qbittorrent rotates it on every container restart and
# logs it once. Once a permanent password is set in the web UI, the
# log line stops appearing in fresh boots and the suffix is omitted.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW=$(sudo docker logs qbittorrent 2>&1 \
  | awk -F': ' '/temporary password/ {print $NF; exit}')
SUFFIX=""
if [ -n "$PW" ]; then
  SUFFIX=" (admin/$PW)"
fi
URL=$(bash "$HERE/../tailscale/https-url.sh" 8080)
echo "qBittorrent:    ${URL:-http://$HOSTNAME:8080}$SUFFIX"
