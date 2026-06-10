#!/usr/bin/env bash
# Sonarr — TV automation. Sits between prowlarr (search) and
# qbittorrent (download), and manages the library of shows you've
# subscribed to. When a new episode drops, sonarr asks prowlarr to
# search every configured indexer, sends the best grab to qbittorrent,
# then imports/renames the completed file into ~/library/media/shows
# where jellyfin sees it.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p \
  ~/library/.config/sonarr \
  ~/library/downloads \
  ~/library/media/shows

sudo ufw allow 8989/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 8989

# URL printed by summary.sh in configure.sh's Phase 3.
