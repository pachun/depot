#!/usr/bin/env bash
# Surface the NAT-PMP forwarded port that ProtonVPN allocated for this
# session. qBittorrent needs it pasted into Connection → "Port used for
# incoming connections" on first run — without that, only outbound
# peers connect and download speeds drop by ~50%.
#
# The port is written by gluetun to /gluetun/forwarded_port; we read
# the host-side bind-mount of that path.
set -euo pipefail
PORT_FILE="$HOME/library/.config/gluetun/forwarded_port"
if [ -f "$PORT_FILE" ] && [ -s "$PORT_FILE" ]; then
  PORT=$(cat "$PORT_FILE")
  echo "Gluetun:        VPN up — qBittorrent peer port: $PORT"
else
  echo "Gluetun:        VPN starting — re-run summary in ~30s, or 'docker logs gluetun'"
fi
