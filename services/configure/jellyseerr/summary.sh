#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL=$(bash "$HERE/../tailscale/https-url.sh" 5055)
echo "Jellyseerr:     ${URL:-http://$HOSTNAME:5055}"
