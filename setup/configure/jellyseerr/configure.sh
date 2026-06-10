#!/usr/bin/env bash
# Jellyseerr — Netflix-style discovery + request UI on top of sonarr
# and radarr. TMDB-driven browse experience for movies and TV;
# clicking "Request" sends the title to sonarr (TV) or radarr (movies),
# which auto-grabs it through the same prowlarr/qbittorrent pipeline.
# Imports your jellyfin user list so anyone with a jellyfin login can
# request.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p ~/library/.config/jellyseerr

sudo ufw allow 5055/tcp

# PUID/PGID not needed — see compose comment. TZ still useful for
# accurate timestamps in jellyseerr's UI.
sudo \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 5055

# URL printed by summary.sh in configure.sh's Phase 3.
