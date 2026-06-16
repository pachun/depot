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

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 9696

# Register the Newznab indexer (NZBGeek) and the Sonarr+Radarr
# Applications via Prowlarr's REST API. Both operations are
# idempotent — looking up by name and PUT-ing if present, POST-ing if
# new. Skipped gracefully on a fresh deploy where Prowlarr hasn't
# generated its API key yet OR where the user hasn't provided an
# indexer API key. Re-running picks both up.
PROWLARR_CONFIG="$HOME/library/.config/prowlarr/config.xml"
USENET_ENV="$HOME/library/.config/depot/usenet.env"

if [ -s "$PROWLARR_CONFIG" ]; then
  PROWLARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$PROWLARR_CONFIG" | head -1)

  if [ -n "$PROWLARR_API_KEY" ]; then
    # shellcheck disable=SC1091
    source "$HERE/../_prowlarr-helpers.sh"

    prowlarr_wait_for_api "http://localhost:9696" "$PROWLARR_API_KEY" || true

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

    # Application bridges so Prowlarr pushes indexer config TO
    # Sonarr + Radarr. Without these the arrs never learn about
    # NZBGeek (or any other indexer Prowlarr knows about).
    SONARR_CONFIG="$HOME/library/.config/sonarr/config.xml"
    if [ -s "$SONARR_CONFIG" ]; then
      SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" | head -1)
      if [ -n "$SONARR_API_KEY" ]; then
        prowlarr_register_application \
          "http://localhost:9696" \
          "$PROWLARR_API_KEY" \
          "Sonarr" \
          "http://host.docker.internal:8989" \
          "$SONARR_API_KEY"
      fi
    fi

    RADARR_CONFIG="$HOME/library/.config/radarr/config.xml"
    if [ -s "$RADARR_CONFIG" ]; then
      RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" | head -1)
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
