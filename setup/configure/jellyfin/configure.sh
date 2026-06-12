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
  ~/library/.config/jellyfin \
  ~/library/media/movies \
  ~/library/media/shows

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
INTRO_SKIPPER_DIR="$HOME/library/.config/jellyfin/data/plugins/Intro Skipper_${INTRO_SKIPPER_VERSION}"

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

# Expose as HTTPS on the same port number via tailscale — reachable
# at https://<hostname>.<tailnet>.ts.net:8096. HTTP on the same port
# stays available as a fallback.
bash "$HERE/../tailscale/expose-https.sh" 8096

# URLs are printed by summary.sh in configure.sh's Phase 3 so every
# service's address lands together at the very end of the output.
