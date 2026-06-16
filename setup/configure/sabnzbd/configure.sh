#!/usr/bin/env bash
# SABnzbd — Usenet equivalent of qbittorrent. Pulls NZB files from
# disk (handed in by sonarr/radarr) and downloads the referenced
# articles from the configured Frugal Usenet server topology. Output
# lands in ~/library/downloads where sonarr/radarr can hardlink it
# into the media tree, same convention as the torrent stack.
#
# Optional: skipped if usenet.env isn't present (the user hasn't run
# the dispatcher's prompts.sh yet). Re-running the dispatcher later
# picks it up. The arr-side registration is idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

USENET_ENV="$HOME/library/.config/depot/usenet.env"
if [ ! -f "$USENET_ENV" ]; then
  echo "sabnzbd skipped — $USENET_ENV not present (prompts.sh first)"
  exit 0
fi
# shellcheck disable=SC1090
source "$USENET_ENV"

if [ -z "${USENET_USERNAME:-}" ] || [ -z "${USENET_PASSWORD:-}" ]; then
  echo "sabnzbd skipped — no Frugal username/password in $USENET_ENV"
  exit 0
fi

mkdir -p \
  ~/library/.config/sabnzbd \
  ~/library/downloads

sudo ufw allow 8085/tcp

# Template sabnzbd.ini on first run only. SABnzbd writes to this file
# whenever the user changes settings in its web UI, so re-templating
# every run would clobber those edits. Initial template seeds the
# three Frugal servers, the categories sonarr/radarr expect, and a
# stable API key we generate (so the arr-side registration below has
# something deterministic to use).
SABNZBD_INI=~/library/.config/sabnzbd/sabnzbd.ini
if [ ! -f "$SABNZBD_INI" ]; then
  SABNZBD_API_KEY=$(openssl rand -hex 16)
  umask 077
  cat > "$SABNZBD_INI" <<EOF
[misc]
api_key = $SABNZBD_API_KEY
nzb_key = $SABNZBD_API_KEY
host = 0.0.0.0
port = 8080
download_dir = /downloads/incomplete
complete_dir = /downloads
# Allow API calls + web UI from the docker bridge (host.docker.internal
# resolves to a 172.x address). Empty list means anyone reachable,
# which is fine on a single-user box behind tailscale.
host_whitelist =
api_logging = 0
inet_exposure = 4

[categories]
[[tv]]
priority = -100
pp = 3
name = tv
dir = /downloads
[[movies]]
priority = -100
pp = 3
name = movies
dir = /downloads

[servers]
[[frugal-primary]]
host = $USENET_PRIMARY_HOST
port = $USENET_PRIMARY_PORT
connections = $USENET_PRIMARY_CONNECTIONS
ssl = 1
username = $USENET_USERNAME
password = $USENET_PASSWORD
priority = 0
enable = 1

[[frugal-secondary]]
host = $USENET_SECONDARY_HOST
port = $USENET_SECONDARY_PORT
connections = $USENET_SECONDARY_CONNECTIONS
ssl = 1
username = $USENET_USERNAME
password = $USENET_PASSWORD
priority = 1
enable = 1

[[frugal-bonus]]
host = $USENET_BONUS_HOST
port = $USENET_BONUS_PORT
connections = $USENET_BONUS_CONNECTIONS
ssl = 1
username = $USENET_USERNAME
password = $USENET_PASSWORD
priority = 2
enable = 1
EOF
fi

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

bash "$HERE/../tailscale/expose-https.sh" 8085

# Read back the API key SABnzbd is actually using (either the one we
# just wrote, or whatever the user has set via the UI on a prior run).
SABNZBD_API_KEY=$(grep -m1 '^api_key' "$SABNZBD_INI" | awk -F'=' '{gsub(/ /, "", $2); print $2}')

# Wait for the SABnzbd API to respond after the container start. On
# first boot this can take 10-20s. Subsequent runs respond instantly.
echo "Waiting for SABnzbd API..."
api_up=0
for _ in $(seq 1 60); do
  if curl -sf "http://localhost:8085/api?mode=version&apikey=$SABNZBD_API_KEY&output=json" \
       >/dev/null 2>&1; then
    api_up=1
    break
  fi
  sleep 1
done

if [ "$api_up" != "1" ]; then
  echo "  WARN: SABnzbd API didn't respond within 60s — skipping arr-side wiring."
  echo "        Re-run setup/configure.sh once SABnzbd is up to register it with"
  echo "        Sonarr/Radarr."
  exit 0
fi

# Register SABnzbd as a download client in Sonarr (TV → tv category)
# and Radarr (movies → movies category). Same upsert-by-name pattern
# the existing Sonarr webhook block uses.
# shellcheck disable=SC1091
source "$HERE/../_arr-download-client.sh"

SONARR_CONFIG="$HOME/library/.config/sonarr/config.xml"
if [ -s "$SONARR_CONFIG" ]; then
  SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" | head -1)
  if [ -n "$SONARR_API_KEY" ]; then
    arr_register_sabnzbd \
      "http://localhost:8989" \
      "v3" \
      "$SONARR_API_KEY" \
      "$SABNZBD_API_KEY" \
      "tv"
  fi
fi

RADARR_CONFIG="$HOME/library/.config/radarr/config.xml"
if [ -s "$RADARR_CONFIG" ]; then
  RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" | head -1)
  if [ -n "$RADARR_API_KEY" ]; then
    arr_register_sabnzbd \
      "http://localhost:7878" \
      "v3" \
      "$RADARR_API_KEY" \
      "$SABNZBD_API_KEY" \
      "movies"
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
