#!/usr/bin/env bash
# qBittorrent — torrent client managed via a web UI on port 8080. Sits
# at the bottom of the arr stack: sonarr/radarr send grabs here, files
# land in ~/library/downloads/, and once the arr tools rename/import
# them they move into ~/library/media/.
#
# Network: qBittorrent shares gluetun's network namespace, so all its
# torrent traffic exits via the ProtonVPN WireGuard tunnel. The web UI
# (8080) and BitTorrent peer port (6881) are published from gluetun's
# compose, not from here. ufw rules for those ports live with gluetun
# too.
#
# The linuxserver image generates a one-time admin password on first
# start and writes it to the container's stdout. We surface it at the
# end so you don't have to docker-logs around for it. After first
# login, set a real password in Tools → Options → Web UI.
#
# Idempotent — `docker-compose up -d` is a no-op when the container is
# already up; mkdir -p is too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"
# qBittorrent's network_mode below needs the gluetun container to
# already exist, so we call its configure.sh directly rather than
# leaning on dispatcher iteration order. Idempotent — same pattern
# as the docker call above.
bash "$HERE/../gluetun/configure.sh"

mkdir -p ~/library/.config/qbittorrent ~/library/downloads

# Pre-seed qBittorrent.conf on a fresh install so that on its very
# first start qBittorrent has "Bypass authentication for clients on
# localhost" enabled. Required for gluetun's qbit-port-sync.sh hook
# to push the NAT-PMP forwarded port into qBittorrent's listening
# port without credentials.
#
# Only writes when the file doesn't exist yet — qBittorrent persists
# its full state to this file on shutdown, so on every later run the
# file already exists with the user's accumulated settings and we
# leave it alone.
QBIT_CONF_DIR=~/library/.config/qbittorrent/qBittorrent/config
QBIT_CONF="$QBIT_CONF_DIR/qBittorrent.conf"
mkdir -p "$QBIT_CONF_DIR"
if [ ! -f "$QBIT_CONF" ]; then
  cat > "$QBIT_CONF" <<'EOF'
[Preferences]
WebUI\LocalHostAuth=false
EOF
fi

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
