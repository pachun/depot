#!/usr/bin/env bash
# Prowlarr — indexer aggregator. Configure your tracker (IPTorrents,
# etc.) credentials here once, then point sonarr and radarr at prowlarr
# and they both inherit every indexer. Without prowlarr you'd be
# pasting the same indexer config into every arr tool separately.
#
# No downloads or media mount — prowlarr only stores indexer configs
# and forwards search queries to sonarr/radarr.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p ~/library/.config/prowlarr

sudo ufw allow 9696/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# URL printed by summary.sh in configure.sh's Phase 3.
