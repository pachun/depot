#!/usr/bin/env bash
# qBittorrent — torrent client managed via a web UI on port 8080. Sits
# at the bottom of the arr stack: sonarr/radarr send grabs here, files
# land in ~/library/downloads/, and once the arr tools rename/import
# them they move into ~/library/media/.
#
# The linuxserver image generates a one-time admin password on first
# start and writes it to the container's stdout. We surface it at the
# end so you don't have to docker-logs around for it. After first
# login, set a real password in Tools → Options → Web UI.
#
# Idempotent — `docker-compose up -d` is a no-op when the container is
# already up; ufw rules and mkdir -p are too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p ~/library/.config/qbittorrent ~/library/downloads

# 8080 = web UI; 6881 = BitTorrent peer port (TCP for peer wire
# protocol, UDP for DHT and uTP). Skipping the UDP rule degrades
# peer discovery and download speeds.
sudo ufw allow 8080/tcp
sudo ufw allow 6881/tcp
sudo ufw allow 6881/udp

# Same env-passing pattern as jellyfin — group membership only kicks
# in on next login, so this run still goes through sudo; PUID/PGID/TZ/
# HOME are passed through explicitly because sudo otherwise resets the
# env and docker-compose needs them to substitute into compose.yml.
sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# URL and (first-run only) temporary admin password are printed by
# summary.sh in configure.sh's Phase 3 so every service's address
# lands together at the very end of the output.
