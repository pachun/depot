#!/usr/bin/env bash
# Docker — infrastructure for the NAS services (jellyfin, eventually
# sonarr/radarr/qbittorrent/jellyseerr/etc.). Each service calls this
# script as a dep, so removing this feature without removing every
# dependent service would surface as a failed run, not a silent
# misconfiguration.
#
# `docker` is the engine; `docker-compose` is a separate package on
# Arch (unlike Docker Desktop on macOS/Windows where compose ships
# bundled with the engine). Idempotent.
set -euo pipefail

# Skip if this service already ran in the current dispatcher
# invocation. Other services may have called us as an explicit
# dependency; without this guard, the cascade re-runs heavy bootstrap
# blocks many times per install. See services/configure.sh.
if [ -n "${DEPOT_RUN_DIR:-}" ]; then
  SENTINEL="$DEPOT_RUN_DIR/$(basename "$(dirname "${BASH_SOURCE[0]}")")"
  [ -f "$SENTINEL" ] && exit 0
  touch "$SENTINEL"
fi

sudo pacman -S --needed --noconfirm docker docker-compose

sudo systemctl enable --now docker.service

# Group membership only takes effect on the next login session, so any
# docker commands during this same configure.sh run still need sudo.
# Worth doing anyway so future sessions can use docker without sudo.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER"
fi
