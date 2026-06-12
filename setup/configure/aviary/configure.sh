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

bash "$HERE/../docker/configure.sh"

# sqlite is needed to harvest the Jellyfin API key (see the Jellyfin
# integration block below). pacman -S --needed is a no-op when present.
sudo pacman -S --needed --noconfirm sqlite

SRC=~/library/apps/aviary
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
SECRET_DIR=~/library/.config/aviary
SECRET_FILE="$SECRET_DIR/secret_key_base"
mkdir -p "$SECRET_DIR"
if [ ! -f "$SECRET_FILE" ]; then
  openssl rand -base64 48 | tr -d '\n' > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi
SECRET_KEY_BASE=$(cat "$SECRET_FILE")

# Jellyfin integration: aviary needs a base URL + API key to call the
# Jellyfin REST API. URL is the internal docker-bridge path (faster
# than going out to Tailscale and back, and doesn't need cert plumbing
# inside the container). API key is harvested directly from Jellyfin's
# own SQLite database — there's no manual paste step.
#
# Cached to ~/library/.config/aviary/.env on first successful harvest;
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
    "$HOME/library/.config/jellyfin/data/data/jellyfin.db" \
    "$HOME/library/.config/jellyfin/data/jellyfin.db"
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
JELLYSEERR_SETTINGS="$HOME/library/.config/jellyseerr/settings.json"

if [ -z "${JELLYSEERR_API_KEY:-}" ] && [ -s "$JELLYSEERR_SETTINGS" ]; then
  JELLYSEERR_API_KEY=$(jq -r '.main.apiKey // empty' "$JELLYSEERR_SETTINGS" 2>/dev/null || true)
  if [ -n "$JELLYSEERR_API_KEY" ]; then
    umask 077
    echo "JELLYSEERR_API_KEY=$JELLYSEERR_API_KEY" >> "$AVIARY_ENV"
  fi
fi
JELLYSEERR_API_KEY="${JELLYSEERR_API_KEY:-}"

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
JELLYFIN_PUBLIC_URL="https://${PHX_HOST}:8096"

sudo \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  SRC="$SRC" \
  SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  PHX_HOST="$PHX_HOST" \
  JELLYFIN_URL="$JELLYFIN_URL" \
  JELLYFIN_PUBLIC_URL="$JELLYFIN_PUBLIC_URL" \
  JELLYFIN_API_KEY="$JELLYFIN_API_KEY" \
  JELLYSEERR_URL="$JELLYSEERR_URL" \
  JELLYSEERR_API_KEY="$JELLYSEERR_API_KEY" \
  docker-compose -f "$HERE/docker-compose.yml" up -d --build

# Expose aviary as HTTPS on 443 → reachable at
# https://<hostname>.<tailnet>.ts.net/ with no port suffix. Phoenix
# release's `force_ssl` + `url: [scheme: "https", port: 443]` are
# already correct because Tailscale Serve sets X-Forwarded-Proto: https
# upstream, so Plug.SSL sees the request as already-TLS and doesn't
# redirect-loop.
bash "$HERE/../tailscale/expose-https.sh" 443 4000
