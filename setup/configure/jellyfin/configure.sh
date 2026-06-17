#!/usr/bin/env bash
# Jellyfin — the media server. Runs as a Docker container (via the
# docker feature) so updates / rollbacks / coexistence with the future
# arr stack are clean. First-time setup (admin user, library paths)
# happens via the web UI at http://<this-machine>:8096 on first browse.
#
# Persistent state lives under ~/jellyfin/ on the host; media files
# live under ~/media and bind-mount into the container at /media so
# jellyfin can see them.
#
# Idempotent: `docker compose up -d` is a no-op when the container is
# already up; the ufw rule and mkdir -p are too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

# Separate per-type folders so jellyfin can pick the right metadata
# provider (movie vs. TV) for each library it scans.
mkdir -p \
  ~/hdds/.config/jellyfin \
  ~/hdds/media/movies \
  ~/hdds/media/tv

sudo ufw allow 8096/tcp

# The user's docker-group membership only takes effect on next login,
# so this run still goes through sudo. Pass PUID/PGID/TZ/HOME through
# explicitly because sudo otherwise resets the env, and docker-compose
# needs those vars to substitute the values referenced by compose.yml.
sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# Drive Jellyfin's first-run wizard via the Startup API — admin user
# creation, Movies + Shows libraries, real-time monitoring,
# aviary + sonarr API keys — so no browser tab needs to be opened on
# a fresh deploy. Idempotent: jellyfin_needs_bootstrap returns false
# on a server where the wizard already completed, and every individual
# upsert checks for existing state before creating.
#
# Skips gracefully if admin.env isn't there (someone running just
# jellyfin/configure.sh without going through the dispatcher's Phase
# 1 prompts). Re-running through the dispatcher fills the gap.
ADMIN_ENV="$HOME/hdds/.config/depot/admin.env"
if [ -f "$ADMIN_ENV" ]; then
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"

  if [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    # shellcheck disable=SC1091
    source "$HERE/bootstrap.sh"

    echo "Bootstrapping Jellyfin..."
    JF_URL="http://localhost:8096"

    if jellyfin_wait_for_api "$JF_URL"; then
      if jellyfin_needs_bootstrap "$JF_URL"; then
        echo "  running first-run wizard"
        jellyfin_run_startup_wizard "$JF_URL" "$ADMIN_USERNAME" "$ADMIN_PASSWORD"
        # After Startup/Complete, Jellyfin restarts internally — wait
        # for the API to come back before logging in.
        sleep 3
        jellyfin_wait_for_api "$JF_URL"
      else
        echo "  wizard already complete — skipping"
      fi

      JF_TOKEN=$(jellyfin_login "$JF_URL" "$ADMIN_USERNAME" "$ADMIN_PASSWORD")
      if [ -n "$JF_TOKEN" ]; then
        echo "  upserting Movies library"
        jellyfin_upsert_library "$JF_URL" "$JF_TOKEN" "Movies" "movies" "/media/movies"

        echo "  upserting Shows library"
        jellyfin_upsert_library "$JF_URL" "$JF_TOKEN" "Shows" "tvshows" "/media/tv"

        echo "  upserting aviary + sonarr API keys"
        jellyfin_upsert_api_key "$JF_URL" "$JF_TOKEN" "aviary" >/dev/null
        jellyfin_upsert_api_key "$JF_URL" "$JF_TOKEN" "sonarr" >/dev/null
      else
        echo "  WARN: login failed — bootstrap steps after this skipped"
      fi
    fi
  fi
fi

# Intro Skipper plugin — auto-detects intros (and credits, recaps,
# previews, commercials) via audio fingerprinting and exposes the
# resulting timestamps on each episode via a REST endpoint. Aviary
# uses this to render the in-player "Skip Intro" pill. Version is
# pinned to the Jellyfin 10.11 build; bump in lockstep with Jellyfin
# major upgrades.
#
# Idempotent: presence of the DLL at the pinned version is the
# "already installed" signal, so reruns skip the download and the
# Jellyfin restart entirely.
INTRO_SKIPPER_VERSION="1.10.11.21"
INTRO_SKIPPER_DIR="$HOME/hdds/.config/jellyfin/data/plugins/Intro Skipper_${INTRO_SKIPPER_VERSION}"

if [ ! -f "$INTRO_SKIPPER_DIR/IntroSkipper.dll" ]; then
  echo "Installing Jellyfin Intro Skipper plugin v${INTRO_SKIPPER_VERSION}..."
  TMPZIP=$(mktemp -t intro-skipper-XXXXXX.zip)
  trap "rm -f '$TMPZIP'" EXIT

  curl -sfL \
    "https://github.com/intro-skipper/intro-skipper/releases/download/10.11/v${INTRO_SKIPPER_VERSION}/intro-skipper-v${INTRO_SKIPPER_VERSION}.zip" \
    -o "$TMPZIP"

  mkdir -p "$INTRO_SKIPPER_DIR"
  unzip -q -o "$TMPZIP" -d "$INTRO_SKIPPER_DIR"

  # Plugins are loaded only at Jellyfin startup, so a restart is
  # required for the new DLL to take effect. After this, the plugin's
  # background scan begins automatically and progresses through the
  # library over hours; episodes get timestamps as their seasons
  # complete fingerprinting.
  docker restart jellyfin >/dev/null
fi

# Enable Intel QuickSync hardware-accelerated transcoding via the
# System/Configuration/encoding REST API. Without this, Jellyfin runs
# every transcode on the CPU and 1080p eats every core — the iGPU
# we passed through via /dev/dri above sits idle. Patches only the
# fields aviary cares about (accel type, decode codecs, 10-bit
# decode), leaving any other user customization intact.
#
# Skips gracefully on a fresh Jellyfin where no 'aviary' API key
# exists yet (first-run wizard hasn't been done) — re-running this
# script after the wizard completes picks it up. The encoding POST
# itself is idempotent.
#
# Wrapped in a subshell + `|| true` so that any failure inside this
# optional block can never propagate up and kill the dispatcher
# (Phase 2 in setup/configure.sh runs under set -e — a non-zero exit
# here would skip the Phase 3 summary print).
echo "Configuring Jellyfin hardware acceleration (QSV)..."
(
  set +e

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

  [ -n "$JF_DB" ] || { echo "  skipped: jellyfin.db not found"; exit 0; }

  JELLYFIN_API_KEY=$(sqlite3 "$JF_DB" \
    "SELECT AccessToken FROM ApiKeys WHERE Name = 'aviary' LIMIT 1;" 2>/dev/null)
  [ -n "$JELLYFIN_API_KEY" ] || {
    echo "  skipped: no 'aviary' API key in Jellyfin yet"
    exit 0
  }

  # Wait for the API to respond. Use /System/Info/Public — it doesn't
  # require auth, so a stale/wrong API key doesn't make every iteration
  # 401 and burn the full window. 30s is enough for the common case
  # (container already up, API responsive on first try); fresh-boot
  # delays are dominated by Jellyfin plugin loading which runs in the
  # background and doesn't block /System/Info/Public.
  api_up=0
  for _ in $(seq 1 30); do
    if curl -sf "http://localhost:8096/System/Info/Public" >/dev/null 2>&1; then
      api_up=1
      break
    fi
    sleep 1
  done
  [ "$api_up" = "1" ] || {
    echo "  skipped: Jellyfin API didn't respond within 30s"
    exit 0
  }

  CURRENT_ENC=$(curl -s -H "X-Emby-Token: $JELLYFIN_API_KEY" \
    "http://localhost:8096/System/Configuration/encoding" 2>/dev/null)

  # Bail unless we got back valid JSON. Jellyfin sometimes returns an
  # HTML 502 from the reverse-proxy edge during boot — jq on that
  # would fail and (with assignment-via-substitution) trip set -e on
  # the next line.
  echo "$CURRENT_ENC" | jq empty >/dev/null 2>&1 || {
    echo "  skipped: encoding config endpoint returned non-JSON"
    exit 0
  }

  PATCHED=$(echo "$CURRENT_ENC" | jq '
    .HardwareAccelerationType = "qsv"
    | .EnableHardwareEncoding = true
    | .HardwareDecodingCodecs = ["h264", "hevc", "mpeg2video", "vc1", "vp8", "vp9"]
    | .EnableDecodingColorDepth10Hevc = true
    | .EnableDecodingColorDepth10Vp9 = true
    | .AllowHevcEncoding = true
  ')

  curl -s -X POST \
    -H "X-Emby-Token: $JELLYFIN_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PATCHED" \
    "http://localhost:8096/System/Configuration/encoding" >/dev/null 2>&1

  echo "  enabled QSV + 10-bit HEVC decode."
) || true

# Expose Jellyfin via tailscale on a DIFFERENT port from the Jellyfin
# bind so the two don't race for port 8096. Jellyfin uses
# `network_mode: host` and binds [::]:8096 (IPv6 wildcard) on the host
# network namespace; tailscale serve also binds tailnet IPs:8096. The
# IPv6 wildcard conflicts with tailscale's specific tailnet IPv6 bind,
# so whichever started first wins the race and the other fails. After
# any Jellyfin container restart (e.g. a devices: change), tailscale
# was already holding the port and Jellyfin couldn't rebind.
#
# Moving tailscale serve to 8443 sidesteps the bind conflict entirely.
# User-facing HTTPS lives at https://<host>.<tailnet>.ts.net:8443/ and
# tailscale proxies to http://localhost:8096 where Jellyfin listens.
# Plain HTTP on 8096 over the tailnet still works.
bash "$HERE/../tailscale/expose-https.sh" 8443 8096

# URLs are printed by summary.sh in configure.sh's Phase 3 so every
# service's address lands together at the very end of the output.
