#!/usr/bin/env bash
# SABnzbd — Usenet equivalent of qbittorrent. Pulls NZB files from
# disk (handed in by sonarr/radarr) and downloads the referenced
# articles from the configured Frugal Usenet server topology.
#
# Storage: everything Usenet stays on the SSD end-to-end — incomplete
# downloads, par2/unrar reassembly, and the completed payload all
# live in ~/downloading/usenet (mapped to /usenet in the container).
# Sonarr/Radarr import directly from /usenet into ~/hdds/media via
# cross-filesystem copy. SAB doesn't seed, so there's no reason to
# keep a copy on the HDD pool — the arrs own the only persistent
# copy once import lands.
#
# Optional: skipped if usenet.env isn't present (the user hasn't run
# the dispatcher's prompts.sh yet). Re-running the dispatcher later
# picks it up. The arr-side registration is idempotent.
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
# Direct deps: sabnzbd registers itself as a download client in
# Sonarr and Radarr (register_sabnzbd_into_arr), which requires both
# arrs' API keys present in their config.xml. Without these explicit
# calls, alphabetical dispatcher order puts sabnzbd ahead of sonarr
# and the arr-side registrations silently skip on first install.
bash "$HERE/../sonarr/configure.sh"
bash "$HERE/../radarr/configure.sh"

sudo pacman -S --needed --noconfirm jq

USENET_ENV="$HOME/hdds/.config/depot/usenet.env"
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
  ~/hdds/.config/sabnzbd \
  ~/downloading/usenet

sudo ufw allow 8085/tcp

# SABnzbd rejects any request whose Host header isn't in its
# host_whitelist (defaults to localhost / 127.0.0.1 only). Tailscale
# serve forwards us as framework-depot.<tailnet>.ts.net:8085, so
# without adding that FQDN to host_whitelist every request 404s with
# "Hostname verification failed." Resolve at deploy-time so the value
# tracks your actual tailnet name.
TAILNET_FQDN=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')

# Template sabnzbd.ini on first run only. SABnzbd writes to this file
# whenever the user changes settings in its web UI, so re-templating
# every run would clobber those edits. Initial template seeds the
# three Frugal servers, the categories sonarr/radarr expect, and a
# stable API key we generate (so the arr-side registration below has
# something deterministic to use).
SABNZBD_INI=~/hdds/.config/sabnzbd/sabnzbd.ini
if [ ! -f "$SABNZBD_INI" ]; then
  SABNZBD_API_KEY=$(openssl rand -hex 16)
  umask 077
  cat > "$SABNZBD_INI" <<EOF
[misc]
api_key = $SABNZBD_API_KEY
nzb_key = $SABNZBD_API_KEY
host = 0.0.0.0
port = 8080
download_dir = /usenet/incomplete
complete_dir = /usenet
# host_whitelist is comma-separated allowed Host header values.
# Includes the tailnet FQDN (so the browser can reach us via
# tailscale serve), the short hostname for SSH-tunnel access, and
# host.docker.internal which is how Sonarr/Radarr reach SABnzbd
# from inside their own containers.
host_whitelist = ${TAILNET_FQDN}, $HOSTNAME, localhost, host.docker.internal
api_logging = 0
inet_exposure = 4

[categories]
[[tv]]
priority = -100
pp = 3
name = tv
dir = /usenet/tv
[[movies]]
priority = -100
pp = 3
name = movies
dir = /usenet/movies

[servers]
[[frugal-primary]]
host = $USENET_PRIMARY_HOST
port = $USENET_PRIMARY_PORT
connections = $USENET_PRIMARY_CONNECTIONS
ssl = 1
username =
password =
priority = 0
enable = 1

[[frugal-secondary]]
host = $USENET_SECONDARY_HOST
port = $USENET_SECONDARY_PORT
connections = $USENET_SECONDARY_CONNECTIONS
ssl = 1
username =
password =
priority = 1
enable = 1

[[frugal-bonus]]
host = $USENET_BONUS_HOST
port = $USENET_BONUS_PORT
connections = $USENET_BONUS_CONNECTIONS
ssl = 1
username =
password =
priority = 2
enable = 1
EOF
fi

# Repair an existing sabnzbd.ini's host_whitelist if it doesn't yet
# match the canonical list — useful for installs that predated this
# fix. The container restart needed to apply this happens further
# below via the SABnzbd API (mode=restart), which restarts the python
# process WITHOUT cycling the docker container — sidesteps the host-
# port-already-bound dance.
#
# host.docker.internal is needed because that's the hostname Sonarr
# and Radarr use to reach SABnzbd from inside their own containers
# (configured during register_sabnzbd_into_arr below). Without it on the
# whitelist, SABnzbd rejects every arr download request with
# "Refused connection with hostname 'host.docker.internal'".
SABNZBD_WHITELIST="${TAILNET_FQDN}, $HOSTNAME, localhost, host.docker.internal"

if [ -n "$TAILNET_FQDN" ] && [ -f "$SABNZBD_INI" ]; then
  if ! grep -q "^host_whitelist = ${SABNZBD_WHITELIST}\$" "$SABNZBD_INI"; then
    sed -i "s|^host_whitelist = .*|host_whitelist = ${SABNZBD_WHITELIST}|" \
      "$SABNZBD_INI"
    SABNZBD_NEEDS_RESTART=1
  fi
fi

# Cleanup: an earlier version of this script exposed SABnzbd via
# tailscale serve on port 8085 — the same port docker-proxy binds
# for the container's host mapping. The two race at container-
# restart time (docker can't rebind a port tailscale's already
# holding), so we tear down that old mapping unconditionally before
# bringing the container up. tailscale serve --off is idempotent;
# no-op when no mapping is present.
sudo tailscale serve --https=8085 off >/dev/null 2>&1 || true

# Defensive: a failed `docker restart` (e.g., from the earlier
# version's port collision) can leave the container in a state
# where it's "Up" but has no port bindings — docker-compose up -d
# then won't touch it, and curl localhost:8085 just refuses.
# Force-recreate when we can't see 8085 in the container's port
# bindings.
if docker inspect sabnzbd >/dev/null 2>&1; then
  if ! docker ps --filter name=sabnzbd --format '{{.Ports}}' | grep -q '8085'; then
    echo "  sabnzbd container's port mapping is missing — recreating"
    docker rm -f sabnzbd >/dev/null
  fi
fi

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# Tailscale serve on 8086 (NOT 8085) — 8085 is docker-proxy's host
# bind for the container. Keeping them on different host ports means
# docker can restart the container cleanly without fighting tailscale
# for the same socket. User-facing HTTPS URL is therefore :8086;
# plain HTTP on 8085 over the tailnet still works.
bash "$HERE/../tailscale/expose-https.sh" 8086 8085

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
  echo "        Re-run services/configure.sh once SABnzbd is up to register it with"
  echo "        Sonarr/Radarr."
  exit 0
fi

# Push the Frugal credentials via SABnzbd's API rather than into the
# templated sabnzbd.ini directly. bash heredocs interpret `$`,
# backticks, and SABnzbd's INI parser treats `#` as a comment start
# mid-line — any of which silently truncates the password the moment
# someone signs up with a real-world strong one. The API takes
# URL-encoded form fields, so neither the shell nor the INI parser
# ever sees the raw password.
#
# Idempotent: re-runs just overwrite with the same values. Also
# correct for a password rotation — edit usenet.env, re-run
# configure.sh, the new password lands.
update_sabnzbd_server_creds() {
  local server_keyword="$1"
  curl -s -X POST \
    --data-urlencode "section=servers" \
    --data-urlencode "keyword=$server_keyword" \
    --data-urlencode "username=$USENET_USERNAME" \
    --data-urlencode "password=$USENET_PASSWORD" \
    --data-urlencode "apikey=$SABNZBD_API_KEY" \
    "http://localhost:8085/api?mode=set_config" >/dev/null
}

update_sabnzbd_server_creds "frugal-primary"
update_sabnzbd_server_creds "frugal-secondary"
update_sabnzbd_server_creds "frugal-bonus"

# Always restart SABnzbd at the end — both the credential update
# above and any host_whitelist sed earlier need a python-process
# restart to take effect. mode=restart does this in place without
# cycling the docker container, sidestepping the host-port-already-
# bound dance.
curl -s "http://localhost:8085/api?mode=restart&apikey=$SABNZBD_API_KEY&output=json" \
  >/dev/null
sleep 2
for _ in $(seq 1 30); do
  if curl -sf "http://localhost:8085/api?mode=version&apikey=$SABNZBD_API_KEY&output=json" \
       >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Register SABnzbd as a download client in Sonarr (TV → tv category)
# and Radarr (movies → movies category). Same upsert-by-name pattern
# the existing Sonarr webhook block uses.
# shellcheck disable=SC1091
source "$HERE/register_into_arrs.sh"

SONARR_CONFIG="$HOME/hdds/.config/sonarr/config.xml"
if [ -s "$SONARR_CONFIG" ]; then
  SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" | head -1 || true)
  if [ -n "$SONARR_API_KEY" ]; then
    register_sabnzbd_into_arr \
      "http://localhost:8989" \
      "v3" \
      "$SONARR_API_KEY" \
      "$SABNZBD_API_KEY" \
      "tv"
  fi
fi

RADARR_CONFIG="$HOME/hdds/.config/radarr/config.xml"
if [ -s "$RADARR_CONFIG" ]; then
  RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" | head -1 || true)
  if [ -n "$RADARR_API_KEY" ]; then
    register_sabnzbd_into_arr \
      "http://localhost:7878" \
      "v3" \
      "$RADARR_API_KEY" \
      "$SABNZBD_API_KEY" \
      "movies"
  fi
fi

# URL printed by summary.sh in configure.sh's Phase 3.
