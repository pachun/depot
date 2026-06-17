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

# Drive Radarr's first-run admin setup via /initialize.json.
ADMIN_ENV="$HOME/library/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"
  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_arr-auth.sh"

    for _ in $(seq 1 30); do
      if curl -sf "http://localhost:7878/api/v3/system/status" >/dev/null 2>&1 \
         || curl -sf "http://localhost:7878/initialize.json" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    arr_initialize_auth \
      "http://localhost:7878" \
      "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "Radarr"
  fi
fi

# Opinionated release-picker policy + first-class bootstrap (root
# folder, qBit download client, Jellyfin notification). All
# idempotent.
#
# Skips gracefully on a fresh Radarr install where config.xml
# doesn't exist yet — re-running this script post-Radarr-setup
# picks it up.
RADARR_CONFIG="$HOME/library/.config/radarr/config.xml"
if [ -s "$RADARR_CONFIG" ]; then
  RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" | head -1)
  if [ -n "$RADARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_arr-profile.sh"
    arr_apply_opinionated_policy "http://localhost:7878" "$RADARR_API_KEY"

    # shellcheck disable=SC1091
    source "$HERE/../_prowlarr-helpers.sh"   # for prowlarr_check_response
    # shellcheck disable=SC1091
    source "$HERE/../_arr-bootstrap.sh"

    arr_upsert_root_folder \
      "http://localhost:7878" "$RADARR_API_KEY" "/movies"

    if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
      arr_upsert_qbittorrent_client \
        "http://localhost:7878" "$RADARR_API_KEY" \
        "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "movies"
    fi

    JF_KEY=$(arr_lookup_jellyfin_api_key "sonarr")
    if [ -n "$JF_KEY" ]; then
      arr_upsert_jellyfin_notification \
        "http://localhost:7878" "$RADARR_API_KEY" "$JF_KEY"
    fi
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
