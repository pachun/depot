#!/usr/bin/env bash
# Surface the NAT-PMP forwarded port that ProtonVPN allocated for this
# session. qbit-port-sync.sh (gluetun's UP_COMMAND hook) has already
# pushed it into qBittorrent's listening-port setting by the time this
# runs, so the value here is informational — no manual paste required.
#
# The port is written by gluetun to /gluetun/forwarded_port; we read
# the host-side bind-mount of that path.
set -euo pipefail
PORT_FILE="$HOME/hdds/.config/gluetun/forwarded_port"
if [ -f "$PORT_FILE" ] && [ -s "$PORT_FILE" ]; then
  PORT=$(cat "$PORT_FILE")
  echo "Gluetun:        VPN up — qBittorrent peer port: $PORT (auto-synced)"
else
  echo "Gluetun:        VPN starting — re-run summary in ~30s, or 'docker logs gluetun'"
fi
