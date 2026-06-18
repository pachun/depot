#!/usr/bin/env bash
# Radarr — movie automation. Structural twin of sonarr but for movies
# rather than TV. Search-and-grab UX for ad-hoc movie downloads, plus
# automatic naming/organization into ~/hdds/media/movies/ where
# jellyfin's Movies library picks them up. Doesn't really do
# subscriptions in any useful way (sequels are too rare to matter),
# but the per-download automation alone is worth the setup.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"
# Direct deps: radarr's connect_to_jellyfin wire needs Jellyfin's
# 'sonarr' API key (shared with sonarr — same key works for both arr
# notifications); its connect_to_qbit wire registers qBittorrent as the
# download client, which radarr validates on save. Calling both
# explicitly so radarr is fully wired on a single install pass —
# independent of alphabetical dispatcher order.
bash "$HERE/../jellyfin/configure.sh"
bash "$HERE/../qbittorrent/configure.sh"

sudo pacman -S --needed --noconfirm jq

mkdir -p \
  ~/hdds/.config/radarr \
  ~/hdds/seeding \
  ~/downloading/usenet \
  ~/hdds/media/movies

sudo ufw allow 7878/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 7878

# Drive Radarr's first-run admin setup via /initialize.json.
ADMIN_ENV="$HOME/hdds/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"
  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/create_admin.sh"

    for _ in $(seq 1 30); do
      if curl -sf "http://localhost:7878/api/v3/system/status" >/dev/null 2>&1 \
         || curl -sf "http://localhost:7878/initialize.json" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    arr_create_admin \
      "http://localhost:7878" \
      "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "Radarr"
  fi
fi

# Opinionated release-picker policy + the standard connections (root
# folder, qBit download client, Jellyfin notification). All
# idempotent.
#
# Skips gracefully on a fresh Radarr install where config.xml
# doesn't exist yet — re-running this script post-Radarr-setup
# picks it up.
RADARR_CONFIG="$HOME/hdds/.config/radarr/config.xml"
if [ -s "$RADARR_CONFIG" ]; then
  RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" | head -1 || true)
  if [ -n "$RADARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/api.sh"
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/opinionate_downloads.sh"
    arr_opinionate_downloads "http://localhost:7878" "$RADARR_API_KEY"

    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/set_library_directory.sh"
    arr_set_library_directory \
      "http://localhost:7878" "$RADARR_API_KEY" "/movies"

    if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
      # shellcheck disable=SC1091
      source "$HERE/../_shared/arr/connect_to_qbit.sh"
      arr_connect_to_qbit \
        "http://localhost:7878" "$RADARR_API_KEY" \
        "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "movies"
    fi

    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/connect_to_jellyfin.sh"
    JF_KEY=$(arr_lookup_jellyfin_api_key "sonarr")
    if [ -n "$JF_KEY" ]; then
      arr_connect_to_jellyfin \
        "http://localhost:7878" "$RADARR_API_KEY" "$JF_KEY"
    fi
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
