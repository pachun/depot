#!/usr/bin/env bash
# Tailscale doesn't have a port — its "URL" is the SSH command that
# works from any tailnet device. The hostname comes from MagicDNS;
# the IP is the fallback for tailnets without MagicDNS enabled.
set -euo pipefail
TAILNET_HOST=$(tailscale status --self --peers=false 2>/dev/null \
  | awk 'NR==1 {print $2}')
TAILNET_IP=$(tailscale ip -4 2>/dev/null | head -1)

if [ -n "$TAILNET_HOST" ]; then
  echo "Tailscale:      ssh $USER@$TAILNET_HOST"
elif [ -n "$TAILNET_IP" ]; then
  echo "Tailscale:      ssh $USER@$TAILNET_IP"
fi
