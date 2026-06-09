#!/usr/bin/env bash
# Temp admin password is sourced from container logs each time —
# linuxserver/qbittorrent rotates it on every container restart and
# logs it once. Once a permanent password is set in the web UI, the
# log line stops appearing in fresh boots and the suffix is omitted.
set -euo pipefail
PW=$(sudo docker logs qbittorrent 2>&1 \
  | awk -F': ' '/temporary password/ {print $NF; exit}')
SUFFIX=""
if [ -n "$PW" ]; then
  SUFFIX=" (admin/$PW)"
fi
echo "qBittorrent:    http://$HOSTNAME:8080$SUFFIX"
