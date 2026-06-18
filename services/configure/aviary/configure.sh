#!/usr/bin/env bash
# Aviary — the unified media app frontend (Phoenix web UI). Lives in
# its own repo at github.com/pachun/aviary so it can iterate without
# tangling with the NAS-setup history here; this feature is the
# integration seam that clones (or syncs) that source and builds the
# docker image so framework-depot always runs the latest pushed main.
#
# Idempotent: fetch + reset --hard is a no-op when already current,
# and docker-compose's layer cache means rebuilds skip unchanged
# layers. fetch + reset rather than pull because this clone is a
# deploy artifact, not a dev tree — a local divergence (which
# shouldn't happen) must never block the deploy.
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
# Direct deps: aviary harvests four API keys to talk to the integration
# layer it sits on top of.
#   - Jellyfin (sqlite DB → 'aviary' key)        — library + playback
#   - Jellyseerr (settings.json → .main.apiKey)  — discover/calendar/TMDB
#   - Sonarr (config.xml → ApiKey)               — TV download buttons
#   - Radarr (config.xml → ApiKey)               — movie download buttons
# All four configs need to exist on disk before aviary's harvest blocks
# below fire. Calling them explicitly here so aviary is single-shot
# installable independent of alphabetical dispatcher order — without
# these, aviary's first iteration runs before the dependent services
# and the harvest skips them, leaving the discover page without
# thumbnails and search/requests broken. Idempotent (per-run guards).
bash "$HERE/../jellyfin/configure.sh"
bash "$HERE/../jellyseerr/configure.sh"
bash "$HERE/../sonarr/configure.sh"
bash "$HERE/../radarr/configure.sh"

# sqlite + jq are used for API-key harvesting: sqlite reads Jellyfin's
# DB, jq parses Jellyseerr's settings.json and Sonarr/Radarr responses
# (and builds the Sonarr notification upsert further down).
# pacman -S --needed is a no-op when present.
sudo pacman -S --needed --noconfirm sqlite jq

SRC=~/hdds/apps/aviary
mkdir -p "$(dirname "$SRC")"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/pachun/aviary.git "$SRC"
else
  git -C "$SRC" fetch origin main
  git -C "$SRC" reset --hard origin/main
fi

# Phoenix release needs a SECRET_KEY_BASE to sign cookies/sessions.
# Generate once, persist, reuse — without persistence, every rebuild
# would invalidate active sessions.
SECRET_DIR=~/hdds/.config/aviary
SECRET_FILE="$SECRET_DIR/secret_key_base"
mkdir -p "$SECRET_DIR"
if [ ! -f "$SECRET_FILE" ]; then
  openssl rand -base64 48 | tr -d '\n' > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi
SECRET_KEY_BASE=$(cat "$SECRET_FILE")

# Shared secret Sonarr's Connect webhook will send back in the
# `x-aviary-secret` header. Same generate-once-and-persist pattern —
# rotating it would break the webhook until Sonarr's notification is
# re-registered, and we don't gain anything by churning it.
WEBHOOK_SECRET_FILE="$SECRET_DIR/sonarr_webhook_secret"
if [ ! -f "$WEBHOOK_SECRET_FILE" ]; then
  openssl rand -hex 32 > "$WEBHOOK_SECRET_FILE"
  chmod 600 "$WEBHOOK_SECRET_FILE"
fi
SONARR_WEBHOOK_SECRET=$(tr -d '\n' < "$WEBHOOK_SECRET_FILE")

# Jellyfin integration: aviary needs a base URL + API key to call the
# Jellyfin REST API. URL is the internal docker-bridge path (faster
# than going out to Tailscale and back, and doesn't need cert plumbing
# inside the container). API key is harvested directly from Jellyfin's
# own SQLite database — there's no manual paste step.
#
# Cached to ~/hdds/.config/aviary/.env on first successful harvest;
# subsequent runs source the cache without re-querying.
#
# Skips gracefully (exit 0, doesn't block other features) if Jellyfin
# isn't initialized yet OR no API key named 'aviary' exists. The user
# message then is: create an 'aviary' API key in Jellyfin admin, re-run
# configure.sh.
AVIARY_ENV="$SECRET_DIR/.env"
JELLYFIN_URL=http://host.docker.internal:8096

if [ -f "$AVIARY_ENV" ]; then
  # shellcheck disable=SC1090
  source "$AVIARY_ENV"
fi

if [ -z "${JELLYFIN_API_KEY:-}" ]; then
  # Find the Jellyfin db — recent versions land at data/data/jellyfin.db
  # but older or migrated installs may have it at data/jellyfin.db. Use
  # whichever exists and is non-empty.
  JF_DB=""
  for candidate in \
    "$HOME/hdds/.config/jellyfin/data/data/jellyfin.db" \
    "$HOME/hdds/.config/jellyfin/data/jellyfin.db"
  do
    if [ -s "$candidate" ]; then
      JF_DB="$candidate"
      break
    fi
  done

  if [ -z "$JF_DB" ]; then
    echo "Aviary skipped — Jellyfin's database doesn't exist yet."
    echo "  Bring Jellyfin up and complete its first-run setup, then generate"
    echo "  an 'aviary' API key (Dashboard → API Keys → '+'), then re-run"
    echo "  configure.sh."
    exit 0
  fi

  # Prefer a key explicitly named 'aviary'. Falling back to any key
  # would risk accidentally adopting Sonarr/Radarr/Jellyseerr's
  # credentials, which audit-trails want kept distinct.
  JELLYFIN_API_KEY=$(sqlite3 "$JF_DB" \
    "SELECT AccessToken FROM ApiKeys WHERE Name = 'aviary' LIMIT 1;" 2>/dev/null || true)

  if [ -z "$JELLYFIN_API_KEY" ]; then
    echo "Aviary skipped — no API key named 'aviary' in Jellyfin yet."
    echo "  Generate one in Jellyfin admin (Dashboard → API Keys → '+',"
    echo "  name it 'aviary'), then re-run configure.sh."
    exit 0
  fi

  umask 077
  echo "JELLYFIN_API_KEY=$JELLYFIN_API_KEY" > "$AVIARY_ENV"
fi

# Jellyseerr integration — powers the release-calendar widget on the
# show detail page (next-episode air dates via TMDB sync). Same
# harvest pattern as Jellyfin: read the API key from Jellyseerr's
# settings.json so there's no manual paste step. Optional — if
# Jellyseerr isn't initialized yet, aviary just falls back to the
# trailer treatment for every show.
JELLYSEERR_URL=http://host.docker.internal:5055
JELLYSEERR_SETTINGS="$HOME/hdds/.config/jellyseerr/settings.json"

if [ -z "${JELLYSEERR_API_KEY:-}" ] && [ -s "$JELLYSEERR_SETTINGS" ]; then
  JELLYSEERR_API_KEY=$(jq -r '.main.apiKey // empty' "$JELLYSEERR_SETTINGS" 2>/dev/null || true)
  if [ -n "$JELLYSEERR_API_KEY" ]; then
    umask 077
    echo "JELLYSEERR_API_KEY=$JELLYSEERR_API_KEY" >> "$AVIARY_ENV"
  fi
fi
JELLYSEERR_API_KEY="${JELLYSEERR_API_KEY:-}"

# Sonarr integration — aviary triggers downloads through Sonarr when
# users hit Watch on a show/season/episode and polls Sonarr's queue
# for download progress to drive the per-button state. Harvested from
# Sonarr's config.xml (same automation pattern as Jellyfin and
# Jellyseerr — no manual paste step).
SONARR_URL=http://host.docker.internal:8989
SONARR_CONFIG="$HOME/hdds/.config/sonarr/config.xml"

if [ -z "${SONARR_API_KEY:-}" ] && [ -s "$SONARR_CONFIG" ]; then
  SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" 2>/dev/null | head -1 || true)
  if [ -n "$SONARR_API_KEY" ]; then
    umask 077
    echo "SONARR_API_KEY=$SONARR_API_KEY" >> "$AVIARY_ENV"
  fi
fi
SONARR_API_KEY="${SONARR_API_KEY:-}"

# Radarr integration — Sonarr's movie sibling. Powers the Watch button
# + progress chip on the movie detail page. Same harvest pattern.
RADARR_URL=http://host.docker.internal:7878
RADARR_CONFIG="$HOME/hdds/.config/radarr/config.xml"

if [ -z "${RADARR_API_KEY:-}" ] && [ -s "$RADARR_CONFIG" ]; then
  RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" 2>/dev/null | head -1 || true)
  if [ -n "$RADARR_API_KEY" ]; then
    umask 077
    echo "RADARR_API_KEY=$RADARR_API_KEY" >> "$AVIARY_ENV"
  fi
fi
RADARR_API_KEY="${RADARR_API_KEY:-}"

sudo ufw allow 4000/tcp

# --build forces a rebuild check on every run; layer cache makes the
# unchanged case fast (Docker resolves the COPY layer against the
# fetched source and finds everything cached).
# PHX_HOST must be the full tailnet FQDN, not the short hostname.
# Phoenix's prod URL config uses this for asset URLs and (crucially)
# for LiveView's WebSocket origin check — a mismatch between the
# requested Host header (which is the FQDN, because the browser hits
# Tailscale Serve at framework-depot.<tailnet>.ts.net) and the
# configured PHX_HOST blocks every WebSocket connect, so LiveView
# shows the "Attempting to reconnect" flash forever.
PHX_HOST=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
if [ -z "$PHX_HOST" ]; then
  PHX_HOST="$HOSTNAME"
fi

# Browser-facing Jellyfin URL. The container reaches Jellyfin over
# host.docker.internal for API calls (JELLYFIN_URL above), but video
# playback URLs are loaded by the user's browser, which can't resolve
# that. Point the browser at Jellyfin's Tailscale-served HTTPS address
# so HLS streams (and image proxying, if we ever stop server-side
# proxying it) work from any tailnet device.
#
# Port 8443 (not 8096): Jellyfin's own bind on the host network owns
# 8096, so tailscale serve for Jellyfin lives on 8443 to avoid the
# bind conflict. See jellyfin/configure.sh for the full story.
JELLYFIN_PUBLIC_URL="https://${PHX_HOST}:8443"

# Aviary's SQLite DB lives on the host (mounted into the container
# at /data) so it survives docker-compose --build wipes of the
# container's writable layer. Create the dir first so the bind
# mount doesn't fail on a fresh box.
#
# We also pass the host uid/gid through to the compose file so the
# container runs as the same user that owns the data dir. The
# aviary image's `USER nobody` (uid 65534) directive would otherwise
# leave the container unable to write the bind-mounted dir (which
# `mkdir` creates as nick:nick 755). The symptom of that mismatch
# was `Aviary.Release.migrate()` timing out with `DBConnection
# connection not available` after 6 s — SQLite spinning on permission
# denied. Keeping ownership as nick also means the DB stays
# inspectable from the host without sudo.
AVIARY_DATA_DIR="$HOME/hdds/.config/aviary/data"
mkdir -p "$AVIARY_DATA_DIR"
HOST_UID=$(id -u)
HOST_GID=$(id -g)

sudo \
  TZ="$(timedatectl show -p Timezone --value)" \
  DEPOT_USER_HOME="$HOME" \
  SRC="$SRC" \
  SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  PHX_HOST="$PHX_HOST" \
  JELLYFIN_URL="$JELLYFIN_URL" \
  JELLYFIN_PUBLIC_URL="$JELLYFIN_PUBLIC_URL" \
  JELLYFIN_API_KEY="$JELLYFIN_API_KEY" \
  JELLYSEERR_URL="$JELLYSEERR_URL" \
  JELLYSEERR_API_KEY="$JELLYSEERR_API_KEY" \
  SONARR_URL="$SONARR_URL" \
  SONARR_API_KEY="$SONARR_API_KEY" \
  SONARR_WEBHOOK_SECRET="$SONARR_WEBHOOK_SECRET" \
  RADARR_URL="$RADARR_URL" \
  RADARR_API_KEY="$RADARR_API_KEY" \
  AVIARY_DATA_DIR="$AVIARY_DATA_DIR" \
  HOST_UID="$HOST_UID" \
  HOST_GID="$HOST_GID" \
  docker-compose -f "$HERE/docker-compose.yml" up -d --build

# Run migrations against the prod DB. Phoenix releases deliberately
# don't auto-migrate on boot; this explicit call keeps the schema in
# sync with the deployed code and is loud about doing so. Idempotent
# — Ecto skips migrations already applied.
docker exec aviary bin/aviary eval "Aviary.Release.migrate()" >/dev/null

# Register (or update) a Webhook Connect notification in Sonarr that
# POSTs back to aviary on health-state events. Aviary uses those
# events to re-fire EpisodeSearch for anything that failed to grab
# during the unhealthy window (most commonly: qBittorrent
# unreachable mid-grab). Idempotent — keyed by the notification
# Name field, we update an existing entry if one is already there.
if [ -n "$SONARR_API_KEY" ]; then
  AVIARY_WEBHOOK_URL="http://host.docker.internal:4000/api/sonarr/webhook"
  # SONARR_URL points the aviary container at sonarr via the docker
  # bridge alias `host.docker.internal`. This curl runs on the host
  # itself, where that alias doesn't resolve — use localhost (sonarr
  # binds host port 8989) so the registration succeeds without DNS.
  SONARR_HOST_URL="http://localhost:8989"

  PAYLOAD=$(cat <<EOF
{
  "name": "Aviary",
  "implementation": "Webhook",
  "implementationName": "Webhook",
  "configContract": "WebhookSettings",
  "tags": [],
  "fields": [
    {"name": "url", "value": "$AVIARY_WEBHOOK_URL"},
    {"name": "method", "value": 1},
    {"name": "username", "value": ""},
    {"name": "password", "value": ""},
    {"name": "headers", "value": [{"key": "x-aviary-secret", "value": "$SONARR_WEBHOOK_SECRET"}]}
  ],
  "onGrab": false,
  "onDownload": false,
  "onUpgrade": false,
  "onRename": false,
  "onSeriesAdd": false,
  "onSeriesDelete": false,
  "onEpisodeFileDelete": false,
  "onEpisodeFileDeleteForUpgrade": false,
  "onHealthIssue": false,
  "onHealthRestored": true,
  "onApplicationUpdate": true,
  "onManualInteractionRequired": false,
  "supportsOnGrab": true,
  "supportsOnDownload": true,
  "supportsOnHealthIssue": true,
  "supportsOnHealthRestored": true,
  "supportsOnApplicationUpdate": true
}
EOF
)

  EXISTING_ID=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
    "${SONARR_HOST_URL}/api/v3/notification" \
    | jq -r '.[] | select(.name=="Aviary") | .id' | head -1)

  if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
    curl -s -X PUT \
      -H "X-Api-Key: $SONARR_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "${SONARR_HOST_URL}/api/v3/notification/${EXISTING_ID}" >/dev/null
  else
    curl -s -X POST \
      -H "X-Api-Key: $SONARR_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "${SONARR_HOST_URL}/api/v3/notification" >/dev/null
  fi
fi

# Expose aviary as HTTPS on 443 → reachable at
# https://<hostname>.<tailnet>.ts.net/ with no port suffix. Phoenix
# release's `force_ssl` + `url: [scheme: "https", port: 443]` are
# already correct because Tailscale Serve sets X-Forwarded-Proto: https
# upstream, so Plug.SSL sees the request as already-TLS and doesn't
# redirect-loop.
bash "$HERE/../tailscale/expose-https.sh" 443 4000
