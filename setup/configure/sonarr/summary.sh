#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL=$(bash "$HERE/../tailscale/https-url.sh" 8989)
echo "Sonarr:         ${URL:-http://$HOSTNAME:8989}"
