#!/usr/bin/env bash
# Gluetun — VPN client container that qBittorrent shares its network
# namespace with. Net effect: every byte qBittorrent sends or receives
# goes through ProtonVPN's WireGuard tunnel; nothing else on this box
# (Jellyfin streams, Sonarr/Radarr API calls, pacman updates, Tailscale)
# pays any VPN overhead.
#
# WireGuard + NAT-PMP port forwarding for full inbound peer capacity.
# Gluetun renews the forwarded port automatically every ~60s; the
# allocated port is stable as long as we're on the same server.
# qbit-port-sync.sh (called by gluetun's VPN_PORT_FORWARDING_UP_COMMAND
# hook) pushes the port into qBittorrent's listening-port setting on
# every allocation/rotation so it stays in sync without manual paste.
#
# FIREWALL_OUTBOUND_SUBNETS whitelists LAN, docker bridge, and tailnet
# CGNAT so the qBittorrent WebUI keeps responding to clients on those
# networks — without it, gluetun's killswitch would only allow outbound
# via the tunnel and WebUI replies to LAN/tailnet would get dropped.
#
# Idempotent — `docker-compose up -d` is a no-op when the container is
# already up and healthy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"
mkdir -p ~/hdds/.config/gluetun

# Make qbit-port-sync.sh available inside the gluetun container at
# /gluetun/qbit-port-sync.sh (the bind-mount target). gluetun's
# VPN_PORT_FORWARDING_UP_COMMAND env var invokes it whenever the
# forwarded port changes.
install -m 0755 "$HERE/qbit-port-sync.sh" ~/hdds/.config/gluetun/qbit-port-sync.sh

# Migration safety: an older qBittorrent container (from before we
# moved 8080/6881 publishing to gluetun) holds the ports gluetun is
# about to bind. Kill it if and only if it's still on the old config;
# qBittorrent's own configure.sh runs after this and brings it back
# up attached to gluetun's netns. The check makes this a no-op once
# qBittorrent is already on the new config.
QBIT_NETMODE=$(sudo docker inspect qbittorrent --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)
if [ -n "$QBIT_NETMODE" ] && [ "$QBIT_NETMODE" != "container:gluetun" ]; then
  echo "Removing pre-gluetun qBittorrent container (will be recreated attached to gluetun)..."
  sudo docker rm -f qbittorrent
fi

# 8080 (qBittorrent web UI) and 6881 (BitTorrent peer port) get
# published from the gluetun container — qBittorrent shares its netns
# and has no port mapping of its own. Rules are idempotent.
sudo ufw allow 8080/tcp
sudo ufw allow 6881/tcp
sudo ufw allow 6881/udp

sudo \
  TZ="$(timedatectl show -p Timezone --value)" \
  WIREGUARD_PRIVATE_KEY="$WIREGUARD_PRIVATE_KEY" \
  WIREGUARD_ADDRESSES="$WIREGUARD_ADDRESSES" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d
