#!/usr/bin/env bash
# Sonarr — TV automation. Sits between prowlarr (search) and
# qbittorrent (download), and manages the library of shows you've
# subscribed to. When a new episode drops, sonarr asks prowlarr to
# search every configured indexer, sends the best grab to qbittorrent,
# then imports/renames the completed file into ~/hdds/media/tv
# where jellyfin sees it.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Skip if this service already ran in the current dispatcher
# invocation. Other services may have called us as an explicit
# dependency; without this guard, the cascade re-runs heavy bootstrap
# blocks many times per install. See services/configure.sh.
#
# When invoked standalone (not via the dispatcher), DEPOT_RUN_DIR
# isn't set in the env yet — initialize it here so the cascade is
# still protected from re-runs within this one invocation. The trap
# only fires for the outermost shell because child `bash subscript.sh`
# calls don't inherit our EXIT handler.
if [ -z "${DEPOT_RUN_DIR:-}" ]; then
  export DEPOT_RUN_DIR=$(mktemp -d -t depot-run-XXXXXXXX)
  trap 'rm -rf "$DEPOT_RUN_DIR"' EXIT
fi
SENTINEL="$DEPOT_RUN_DIR/$(basename "$HERE")"
[ -f "$SENTINEL" ] && exit 0
touch "$SENTINEL"

bash "$HERE/../docker/configure.sh"
# Direct deps: sonarr's connect_to_jellyfin wire needs Jellyfin's
# 'sonarr' API key (created during Jellyfin's bootstrap); its
# connect_to_qbit wire registers qBittorrent as the download client,
# which sonarr validates on save. Calling both explicitly so sonarr is
# fully wired on a single install pass — independent of alphabetical
# dispatcher order.
bash "$HERE/../jellyfin/configure.sh"
bash "$HERE/../qbittorrent/configure.sh"

sudo pacman -S --needed --noconfirm jq

mkdir -p \
  ~/hdds/.config/sonarr \
  ~/hdds/seeding \
  ~/downloading/usenet \
  ~/hdds/media/tv

sudo ufw allow 8989/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  DEPOT_USER_HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 8989

# Drive Sonarr's first-run admin setup via /initialize.json. Idempotent
# — arr_create_admin treats 409 (already configured) as success.
ADMIN_ENV="$HOME/hdds/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"
  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/create_admin.sh"

    for _ in $(seq 1 30); do
      if curl -sf "http://localhost:8989/api/v3/system/status" >/dev/null 2>&1 \
         || curl -sf "http://localhost:8989/initialize.json" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    arr_create_admin \
      "http://localhost:8989" \
      "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "Sonarr"
  fi
fi

# Opinionated release-picker policy + the standard connections (root
# folder, qBit download client, Jellyfin notification). All
# idempotent — lookup-by-name/path, PUT or POST.
#
# Skips gracefully on a fresh Sonarr install where config.xml
# doesn't exist yet — re-running this script post-Sonarr-setup
# picks it up.
SONARR_CONFIG="$HOME/hdds/.config/sonarr/config.xml"
if [ -s "$SONARR_CONFIG" ]; then
  SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" | head -1 || true)
  if [ -n "$SONARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/api.sh"
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/opinionate_downloads.sh"
    arr_opinionate_downloads "http://localhost:8989" "$SONARR_API_KEY"

    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/set_library_directory.sh"
    arr_set_library_directory \
      "http://localhost:8989" "$SONARR_API_KEY" "/tv"

    # qBittorrent download client. Reads creds from admin.env (same
    # ones used for qBit's own admin user).
    if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
      # shellcheck disable=SC1091
      source "$HERE/../_shared/arr/connect_to_qbit.sh"
      arr_connect_to_qbit \
        "http://localhost:8989" "$SONARR_API_KEY" \
        "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "tv"
    fi

    # Jellyfin notification — uses the 'sonarr' API key created
    # during Jellyfin bootstrap. Skipped if Jellyfin isn't set up
    # yet OR the key wasn't created (manual setup).
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/connect_to_jellyfin.sh"
    JF_KEY=$(arr_lookup_jellyfin_api_key "sonarr")
    if [ -n "$JF_KEY" ]; then
      arr_connect_to_jellyfin \
        "http://localhost:8989" "$SONARR_API_KEY" "$JF_KEY"
    fi
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
