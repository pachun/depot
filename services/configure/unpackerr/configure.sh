#!/usr/bin/env bash
# unpackerr — auto-extraction sidecar for the arr stack. Watches the
# /downloads tree shared with qBittorrent and Sonarr/Radarr, extracts
# any archive (RAR, 7z, multi-part, ZIP) the moment a torrent
# completes, then pokes Sonarr/Radarr to re-trigger the import that
# would otherwise sit forever in `importPending` because the *arr
# stack can't handle archives on its own. The depot dispatcher runs
# sonarr/ and radarr/ before this directory (alphabetical order), so
# their config.xml files exist by the time we harvest the API keys.
#
# Idempotent. If Sonarr/Radarr aren't initialized yet, their config
# files won't exist and we run unpackerr with empty API keys — it
# starts cleanly and does nothing until a later configure.sh run
# fills them in.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Skip if this service already ran in the current dispatcher
# invocation. Other services may have called us as an explicit
# dependency; without this guard, the cascade re-runs heavy bootstrap
# blocks many times per install. See services/configure.sh.
#
# When invoked standalone (not via the dispatcher), DEPOT_RUN_DIR
# isn't set in the env yet — initialize it here so the cascade is
# still protected from re-runs within this one invocation. The trap
# only fires for the outermost shell because child `bash subscript.sh`
# calls don't inherit our EXIT handler.
if [ -z "${DEPOT_RUN_DIR:-}" ]; then
  export DEPOT_RUN_DIR=$(mktemp -d -t depot-run-XXXXXXXX)
  trap 'rm -rf "$DEPOT_RUN_DIR"' EXIT
fi
SENTINEL="$DEPOT_RUN_DIR/$(basename "$HERE")"
[ -f "$SENTINEL" ] && exit 0
touch "$SENTINEL"

bash "$HERE/../docker/configure.sh"

# Same API-key harvest pattern aviary/configure.sh uses for Sonarr —
# both *arr services keep their key in config.xml under <ApiKey>.
SONARR_CONFIG="$HOME/hdds/.config/sonarr/config.xml"
RADARR_CONFIG="$HOME/hdds/.config/radarr/config.xml"

SONARR_API_KEY=""
RADARR_API_KEY=""

if [ -s "$SONARR_CONFIG" ]; then
  SONARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$SONARR_CONFIG" 2>/dev/null | head -1 || true)
fi

if [ -s "$RADARR_CONFIG" ]; then
  RADARR_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$RADARR_CONFIG" 2>/dev/null | head -1 || true)
fi

# Same env-passing pattern qbittorrent/configure.sh uses — PUID/PGID
# matter so extracted files land owned by the host user, not root.
sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  DEPOT_USER_HOME="$HOME" \
  SONARR_API_KEY="$SONARR_API_KEY" \
  RADARR_API_KEY="$RADARR_API_KEY" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# No web UI to expose via tailscale. summary.sh confirms the daemon
# is up so the bottom-of-output address list still includes a line
# for this service.
