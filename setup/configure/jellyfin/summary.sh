#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL=$(bash "$HERE/../tailscale/https-url.sh" 8096)
echo "Jellyfin:       ${URL:-http://$HOSTNAME:8096}"
