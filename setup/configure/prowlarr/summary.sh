#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL=$(bash "$HERE/../tailscale/https-url.sh" 9696)
echo "Prowlarr:       ${URL:-http://$HOSTNAME:9696}"
