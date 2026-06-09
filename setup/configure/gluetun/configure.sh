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
# summary.sh prints it so it can be pasted into qBittorrent's
# Connection settings on first run.
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
mkdir -p ~/library/.config/gluetun

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
