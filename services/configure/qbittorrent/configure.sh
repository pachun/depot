#!/usr/bin/env bash
# qBittorrent — torrent client managed via a web UI on port 8080. Sits
# at the bottom of the arr stack: sonarr/radarr send grabs here.
#
# Storage split: incomplete downloads land on the SSD
# (~/downloading/torrents → /torrents in the container), completed
# torrents move to the HDD pool (~/hdds/seeding → /seeding in the
# container) where qBit keeps seeding. The arrs hardlink-import from
# /seeding into ~/hdds/media/{tv,movies} — both paths on the same
# ZFS dataset, so hardlinks work and no double-storage during seeding.
#
# Network: qBittorrent shares gluetun's network namespace, so all its
# torrent traffic exits via the ProtonVPN WireGuard tunnel. The web UI
# (8080) and BitTorrent peer port (6881) are published from gluetun's
# compose, not from here. ufw rules for those ports live with gluetun
# too.
#
# The linuxserver image generates a one-time admin password on first
# start and writes it to the container's stdout. We surface it at the
# end so you don't have to docker-logs around for it. After first
# login, set a real password in Tools → Options → Web UI.
#
# Idempotent — `docker-compose up -d` is a no-op when the container is
# already up; mkdir -p is too.
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
# qBittorrent's network_mode below needs the gluetun container to
# already exist, so we call its configure.sh directly rather than
# leaning on dispatcher iteration order. Idempotent — same pattern
# as the docker call above.
bash "$HERE/../gluetun/configure.sh"

sudo pacman -S --needed --noconfirm jq

mkdir -p ~/hdds/.config/qbittorrent ~/hdds/seeding ~/downloading/torrents

# Pre-seed qBittorrent.conf on a fresh install so that on its very
# first start qBittorrent has "Bypass authentication for clients on
# localhost" enabled. Required for gluetun's qbit-port-sync.sh hook
# to push the NAT-PMP forwarded port into qBittorrent's listening
# port without credentials.
#
# Only writes when the file doesn't exist yet — qBittorrent persists
# its full state to this file on shutdown, so on every later run the
# file already exists with the user's accumulated settings and we
# leave it alone.
QBIT_CONF_DIR=~/hdds/.config/qbittorrent/qBittorrent/config
QBIT_CONF="$QBIT_CONF_DIR/qBittorrent.conf"
mkdir -p "$QBIT_CONF_DIR"
if [ ! -f "$QBIT_CONF" ]; then
  cat > "$QBIT_CONF" <<'EOF'
[Preferences]
WebUI\LocalHostAuth=false
EOF
fi

# Same env-passing pattern as jellyfin — group membership only kicks
# in on next login, so this run still goes through sudo; PUID/PGID/TZ/
# HOME are passed through explicitly because sudo otherwise resets the
# env and docker-compose needs them to substitute into compose.yml.
sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  DEPOT_USER_HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# HTTPS on the same port via tailscale; HTTP stays available.
bash "$HERE/../tailscale/expose-https.sh" 8080

# Drive the qBittorrent first-run admin setup: scrape the temp
# password the LSIO image logs on first boot, log in, change to
# ADMIN_USERNAME / ADMIN_PASSWORD, create the tv + movies categories
# Sonarr/Radarr expect, and add the docker bridge subnet to the
# auth-bypass list so arr containers reaching qBit at
# host.docker.internal don't need to handshake every call.
#
# Idempotent: on a second run the temp password is gone and we
# successfully log in with the admin creds instead — the rest of
# the steps then no-op on already-correct state.
ADMIN_ENV="$HOME/hdds/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"

  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    echo "Bootstrapping qBittorrent..."

    QBIT_URL="http://localhost:8080"

    # Wait for qBit to come up. Fresh container needs ~5-10s.
    for _ in $(seq 1 30); do
      if curl -sf "$QBIT_URL/api/v2/app/version" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    # First-run: LSIO logs the temp password as
    #   "A temporary password is provided for this session: <TEMPPASS>"
    # or older variants. Scrape from container logs; fall back to
    # "adminadmin" (LSIO's older default) if scrape misses.
    #
    # `|| true` because on a re-run of an already-bootstrapped qBit
    # the temp-password line has long since rolled out of the log
    # buffer, so grep returns 1 — pipefail would propagate that into
    # the command substitution and the script's set -e would kill
    # the dispatcher, taking every later service's configure + the
    # Phase 3 summary down with it. The `[ -z ]` fallback below is
    # the actual "no temp password found" path.
    TEMP_PASS=$(docker logs qbittorrent 2>&1 \
      | grep -oP '(?<=temporary password is provided for this session: )\S+' \
      | tail -1 \
      || true)
    [ -z "$TEMP_PASS" ] && TEMP_PASS="adminadmin"

    qbit_cookie_jar=$(mktemp)
    trap 'rm -f "$qbit_cookie_jar"' EXIT

    # Try the admin creds first (idempotent path); fall back to temp.
    qbit_login() {
      curl -s -c "$qbit_cookie_jar" -X POST \
        --data-urlencode "username=$1" \
        --data-urlencode "password=$2" \
        -o /dev/null -w '%{http_code}' \
        "$QBIT_URL/api/v2/auth/login"
    }

    LOGIN_STATUS=$(qbit_login "$ADMIN_USERNAME" "$ADMIN_PASSWORD")
    if [ "$LOGIN_STATUS" != "200" ]; then
      LOGIN_STATUS=$(qbit_login "admin" "$TEMP_PASS")
    fi

    if [ "$LOGIN_STATUS" = "200" ]; then
      # Update credentials + auth-bypass settings. setPreferences takes
      # a JSON blob in a `json` form field — URL-encode it to keep the
      # quoting honest.
      # Set credentials + auth-bypass + the storage-split paths.
      # temp_path is the SSD-backed incomplete folder (/torrents in
      # the container, mapped from ~/downloading/torrents on the
      # host); save_path is the HDD-backed completed folder (/seeding
      # in the container, mapped from ~/hdds/seeding).
      PREFS=$(jq -nc \
        --arg user "$ADMIN_USERNAME" \
        --arg pass "$ADMIN_PASSWORD" \
        '{
          web_ui_username: $user,
          web_ui_password: $pass,
          bypass_local_auth: true,
          bypass_auth_subnet_whitelist_enabled: true,
          bypass_auth_subnet_whitelist: "172.16.0.0/12,127.0.0.0/8",
          temp_path_enabled: true,
          temp_path: "/torrents",
          save_path: "/seeding"
        }')
      curl -s -b "$qbit_cookie_jar" -X POST \
        --data-urlencode "json=$PREFS" \
        "$QBIT_URL/api/v2/app/setPreferences" >/dev/null

      # Create tv + movies categories Sonarr/Radarr expect. Idempotent
      # — qBit returns 200 even if the category already exists. Save
      # paths under /seeding/<category> so completed files land
      # organized on the HDD pool.
      curl -s -b "$qbit_cookie_jar" -X POST \
        --data-urlencode "category=tv" \
        --data-urlencode "savePath=/seeding/tv" \
        "$QBIT_URL/api/v2/torrents/createCategory" >/dev/null
      curl -s -b "$qbit_cookie_jar" -X POST \
        --data-urlencode "category=movies" \
        --data-urlencode "savePath=/seeding/movies" \
        "$QBIT_URL/api/v2/torrents/createCategory" >/dev/null

      echo "  admin creds + categories applied"
    else
      echo "  WARN: couldn't log into qBittorrent (status $LOGIN_STATUS)"
    fi
  fi
fi

# URL is printed by summary.sh in configure.sh's Phase 3 so every
# service's address lands together at the very end of the output.
