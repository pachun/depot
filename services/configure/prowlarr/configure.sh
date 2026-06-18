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

# Skip if this service already ran in the current dispatcher
# invocation. Other services may have called us as an explicit
# dependency; without this guard, the cascade re-runs heavy bootstrap
# blocks many times per install. See services/configure.sh.
if [ -n "${DEPOT_RUN_DIR:-}" ]; then
  SENTINEL="$DEPOT_RUN_DIR/$(basename "$HERE")"
  [ -f "$SENTINEL" ] && exit 0
  touch "$SENTINEL"
fi

bash "$HERE/../docker/configure.sh"
# Direct deps: prowlarr's Application wiring registers Sonarr and
# Radarr by reading their API keys from config.xml. Without these
# explicit calls, alphabetical dispatcher order puts prowlarr ahead
# of sonarr/radarr and the Application wires silently skip on first
# install.
bash "$HERE/../sonarr/configure.sh"
bash "$HERE/../radarr/configure.sh"

sudo pacman -S --needed --noconfirm jq

mkdir -p ~/hdds/.config/prowlarr

sudo ufw allow 9696/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  DEPOT_USER_HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 9696

# Drive Prowlarr's first-run admin setup via /initialize.json. Skip
# gracefully on a server where auth is already configured (the call
# 409s, which arr_create_admin treats as success).
ADMIN_ENV="$HOME/hdds/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"
  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/create_admin.sh"

    # Wait for Prowlarr to come up — fresh containers need 5-10s.
    for _ in $(seq 1 30); do
      if curl -sf "http://localhost:9696/api/v1/system/status" >/dev/null 2>&1 \
         || curl -sf "http://localhost:9696/initialize.json" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    arr_create_admin \
      "http://localhost:9696" \
      "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "Prowlarr"
  fi
fi

# Register indexers + Sonarr/Radarr Applications via Prowlarr's REST
# API. All operations idempotent — lookup-by-name then PUT or POST.
# Skipped gracefully on a fresh deploy where Prowlarr hasn't
# generated its API key yet OR where the user hasn't provided an
# indexer API key. Re-running picks both up.
PROWLARR_CONFIG="$HOME/hdds/.config/prowlarr/config.xml"
USENET_ENV="$HOME/hdds/.config/depot/usenet.env"
IPT_ENV="$HOME/hdds/.config/depot/iptorrents.env"

if [ -s "$PROWLARR_CONFIG" ]; then
  PROWLARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$PROWLARR_CONFIG" | head -1 || true)

  if [ -n "$PROWLARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_shared/arr/api.sh"
    # shellcheck disable=SC1091
    source "$HERE/wire_indexers.sh"
    # shellcheck disable=SC1091
    source "$HERE/wire_arrs.sh"

    arr_wait_for_api "http://localhost:9696" "v1" "$PROWLARR_API_KEY" || true

    # Newznab indexer — keyed by indexer name "NZBGeek". Reads URL +
    # API key from usenet.env (created by sabnzbd/prompts.sh; users
    # who run prowlarr without sabnzbd can also drop the indexer
    # creds into the same file).
    if [ -f "$USENET_ENV" ]; then
      # shellcheck disable=SC1090
      source "$USENET_ENV"
      if [ -n "${INDEXER_NZBGEEK_API_KEY:-}" ]; then
        prowlarr_register_newznab \
          "http://localhost:9696" \
          "$PROWLARR_API_KEY" \
          "NZBGeek" \
          "${INDEXER_NZBGEEK_URL:-https://api.nzbgeek.info}" \
          "$INDEXER_NZBGEEK_API_KEY"
      fi
    fi

    # IPTorrents — reads the cookie + user-agent the user pasted in
    # during prowlarr/prompts.sh. The cookie expires periodically;
    # edit iptorrents.env + re-run configure.sh to refresh.
    if [ -f "$IPT_ENV" ]; then
      # shellcheck disable=SC1090
      source "$IPT_ENV"
      if [ -n "${IPT_COOKIE:-}" ] && [ -n "${IPT_USERAGENT:-}" ]; then
        prowlarr_register_iptorrents \
          "http://localhost:9696" \
          "$PROWLARR_API_KEY" \
          "$IPT_COOKIE" \
          "$IPT_USERAGENT"
      fi
    fi

    # Application bridges so Prowlarr pushes indexer config TO
    # Sonarr + Radarr. Without these the arrs never learn about
    # NZBGeek (or any other indexer Prowlarr knows about).
    SONARR_CONFIG="$HOME/hdds/.config/sonarr/config.xml"
    if [ -s "$SONARR_CONFIG" ]; then
      SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" | head -1 || true)
      if [ -n "$SONARR_API_KEY" ]; then
        prowlarr_register_application \
          "http://localhost:9696" \
          "$PROWLARR_API_KEY" \
          "Sonarr" \
          "http://host.docker.internal:8989" \
          "$SONARR_API_KEY"
      fi
    fi

    RADARR_CONFIG="$HOME/hdds/.config/radarr/config.xml"
    if [ -s "$RADARR_CONFIG" ]; then
      RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" | head -1 || true)
      if [ -n "$RADARR_API_KEY" ]; then
        prowlarr_register_application \
          "http://localhost:9696" \
          "$PROWLARR_API_KEY" \
          "Radarr" \
          "http://host.docker.internal:7878" \
          "$RADARR_API_KEY"
      fi
    fi
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
