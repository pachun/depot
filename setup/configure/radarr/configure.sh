#!/usr/bin/env bash
# Radarr — movie automation. Structural twin of sonarr but for movies
# rather than TV. Search-and-grab UX for ad-hoc movie downloads, plus
# automatic naming/organization into ~/library/media/movies/ where
# jellyfin's Movies library picks them up. Doesn't really do
# subscriptions in any useful way (sequels are too rare to matter),
# but the per-download automation alone is worth the setup.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p \
  ~/library/.config/radarr \
  ~/library/downloads \
  ~/library/media/movies

sudo ufw allow 7878/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 7878

# Opinionated release-picker policy: English-only language on every
# quality profile, and -10000 custom-format scores for Audio
# Description tracks, theater cam-rips/telesync/screener, and a
# small set of known low-quality release groups. See
# _arr-profile.sh for the full payloads + logic.
#
# Skips gracefully on a fresh Radarr install where config.xml
# doesn't exist yet — re-running this script post-Radarr-setup
# picks it up. The arr-profile helper itself is idempotent.
RADARR_CONFIG="$HOME/library/.config/radarr/config.xml"
if [ -s "$RADARR_CONFIG" ]; then
  RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" | head -1)
  if [ -n "$RADARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_arr-profile.sh"
    arr_apply_opinionated_policy "http://localhost:7878" "$RADARR_API_KEY"
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
