#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL=$(bash "$HERE/../tailscale/https-url.sh" 8086)
echo "SABnzbd:        ${URL:-http://$HOSTNAME:8085}"
