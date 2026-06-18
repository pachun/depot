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
# Direct deps: jellyseerr's bootstrap calls Jellyfin's auth endpoint
# with admin creds and reads Sonarr's + Radarr's API keys from their
# config.xml to register them as media backends. Calling all three
# explicitly so jellyseerr is fully wired on a single install pass —
# without these, alphabetical dispatcher order puts jellyseerr ahead
# of sonarr/radarr and the bootstrap silently skips those wires.
bash "$HERE/../jellyfin/configure.sh"
bash "$HERE/../sonarr/configure.sh"
bash "$HERE/../radarr/configure.sh"

sudo pacman -S --needed --noconfirm jq

mkdir -p ~/hdds/.config/jellyseerr

sudo ufw allow 5055/tcp

# PUID/PGID not needed — see compose comment. TZ still useful for
# accurate timestamps in jellyseerr's UI.
sudo \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 5055

# Drive Jellyseerr's first-run setup wizard via its REST API: adopt
# the Jellyfin admin user, wire the Jellyfin → Sonarr → Radarr
# pipeline so Request flows just work. Idempotent — each step checks
# for existing state before configuring.
#
# Skips gracefully if dependent services don't exist yet (Jellyfin
# api key, sonarr/radarr config). Re-running configure.sh after they
# do picks them up.
ADMIN_ENV="$HOME/hdds/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"

  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    JS_URL="http://localhost:5055"

    for _ in $(seq 1 30); do
      if curl -sf "$JS_URL/api/v1/status" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    # Has the wizard completed? Jellyseerr's status endpoint includes
    # `initialized` (older) or we infer from settings/main returning
    # a configured object.
    JS_INITIALIZED=$(curl -s "$JS_URL/api/v1/status" \
      | jq -r '.initialized // false' 2>/dev/null)

    if [ "$JS_INITIALIZED" != "true" ]; then
      echo "Bootstrapping Jellyseerr..."

      # 1) Adopt the Jellyfin admin user. Jellyseerr's
      #    /api/v1/auth/jellyfin endpoint takes the Jellyfin URL +
      #    admin credentials and uses them both to create the
      #    Jellyseerr admin and to wire the Jellyfin connection.
      curl -s -X POST -H "Content-Type: application/json" \
        -c /tmp/js-cookie -b /tmp/js-cookie \
        -d "$(jq -nc \
              --arg url "http://host.docker.internal:8096" \
              --arg user "$ADMIN_USERNAME" \
              --arg pass "$ADMIN_PASSWORD" \
              '{hostname: $url, port: 8096, useSsl: false, username: $user, password: $pass, urlBase: ""}')" \
        "$JS_URL/api/v1/auth/jellyfin" >/dev/null

      # 2) Mark wizard complete in the main settings + flag this
      #    as a managed install.
      curl -s -X POST -H "Content-Type: application/json" \
        -c /tmp/js-cookie -b /tmp/js-cookie \
        -d '{"initialized": true}' \
        "$JS_URL/api/v1/settings/main" >/dev/null

      # 3) Wire Sonarr.
      SONARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' \
        "$HOME/hdds/.config/sonarr/config.xml" 2>/dev/null | head -1 || true)
      if [ -n "$SONARR_KEY" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
          -c /tmp/js-cookie -b /tmp/js-cookie \
          -d "$(jq -nc --arg key "$SONARR_KEY" '{
            name: "Sonarr",
            hostname: "host.docker.internal",
            port: 8989,
            useSsl: false,
            apiKey: $key,
            activeProfileId: 4,
            activeProfileName: "HD-1080p",
            rootFolder: "/shows",
            isDefault: true,
            externalUrl: "",
            syncEnabled: true,
            preventSearch: false
          }')" \
          "$JS_URL/api/v1/settings/sonarr" >/dev/null
      fi

      # 4) Wire Radarr.
      RADARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' \
        "$HOME/hdds/.config/radarr/config.xml" 2>/dev/null | head -1 || true)
      if [ -n "$RADARR_KEY" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
          -c /tmp/js-cookie -b /tmp/js-cookie \
          -d "$(jq -nc --arg key "$RADARR_KEY" '{
            name: "Radarr",
            hostname: "host.docker.internal",
            port: 7878,
            useSsl: false,
            apiKey: $key,
            activeProfileId: 4,
            activeProfileName: "HD-1080p",
            rootFolder: "/movies",
            isDefault: true,
            externalUrl: "",
            minimumAvailability: "released",
            syncEnabled: true,
            preventSearch: false
          }')" \
          "$JS_URL/api/v1/settings/radarr" >/dev/null
      fi

      rm -f /tmp/js-cookie
      echo "  wizard complete + Jellyfin/Sonarr/Radarr wired"
    else
      echo "Jellyseerr already initialized — skipping wizard"
    fi
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
