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

# Opinionated release-picker policy: English-only language on every
# quality profile, and -10000 custom-format scores for Audio
# Description tracks, theater cam-rips/telesync/screener, and a
# small set of known low-quality release groups. See
# _arr-profile.sh for the full payloads + logic.
#
# Skips gracefully on a fresh Sonarr install where config.xml
# doesn't exist yet — re-running this script post-Sonarr-setup
# picks it up. The arr-profile helper itself is idempotent.
SONARR_CONFIG="$HOME/library/.config/sonarr/config.xml"
if [ -s "$SONARR_CONFIG" ]; then
  SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" | head -1)
  if [ -n "$SONARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_arr-profile.sh"
    arr_apply_opinionated_policy "http://localhost:8989" "$SONARR_API_KEY"
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
