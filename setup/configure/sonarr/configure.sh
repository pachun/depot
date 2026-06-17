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

# Drive Sonarr's first-run admin setup via /initialize.json. Idempotent
# — arr_initialize_auth treats 409 (already configured) as success.
ADMIN_ENV="$HOME/library/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"
  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_arr-auth.sh"

    for _ in $(seq 1 30); do
      if curl -sf "http://localhost:8989/api/v3/system/status" >/dev/null 2>&1 \
         || curl -sf "http://localhost:8989/initialize.json" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    arr_initialize_auth \
      "http://localhost:8989" \
      "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "Sonarr"
  fi
fi

# Opinionated release-picker policy + first-class bootstrap (root
# folder, qBit download client, Jellyfin notification). All
# idempotent — lookup-by-name/path, PUT or POST.
#
# Skips gracefully on a fresh Sonarr install where config.xml
# doesn't exist yet — re-running this script post-Sonarr-setup
# picks it up.
SONARR_CONFIG="$HOME/library/.config/sonarr/config.xml"
if [ -s "$SONARR_CONFIG" ]; then
  SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" | head -1)
  if [ -n "$SONARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_arr-profile.sh"
    arr_apply_opinionated_policy "http://localhost:8989" "$SONARR_API_KEY"

    # shellcheck disable=SC1091
    source "$HERE/../_prowlarr-helpers.sh"   # for prowlarr_check_response
    # shellcheck disable=SC1091
    source "$HERE/../_arr-bootstrap.sh"

    arr_upsert_root_folder \
      "http://localhost:8989" "$SONARR_API_KEY" "/shows"

    # qBittorrent download client. Reads creds from admin.env (same
    # ones used for qBit's own admin user).
    if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
      arr_upsert_qbittorrent_client \
        "http://localhost:8989" "$SONARR_API_KEY" \
        "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "tv"
    fi

    # Jellyfin notification — uses the 'sonarr' API key created
    # during Jellyfin bootstrap. Skipped if Jellyfin isn't set up
    # yet OR the key wasn't created (manual setup).
    JF_KEY=$(arr_lookup_jellyfin_api_key "sonarr")
    if [ -n "$JF_KEY" ]; then
      arr_upsert_jellyfin_notification \
        "http://localhost:8989" "$SONARR_API_KEY" "$JF_KEY"
    fi
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
