#!/usr/bin/env bash
# Docker — infrastructure for the NAS services (jellyfin, eventually
# sonarr/radarr/qbittorrent/jellyseerr/etc.). Each service calls this
# script as a dep, so removing this feature without removing every
# dependent service would surface as a failed run, not a silent
# misconfiguration.
#
# The `docker` package on current Arch includes the compose v2 plugin
# (`docker compose ...`), so a separate docker-compose package isn't
# needed. Idempotent.
set -euo pipefail

sudo pacman -S --needed --noconfirm docker

sudo systemctl enable --now docker.service

# Group membership only takes effect on the next login session, so any
# docker commands during this same configure.sh run still need sudo.
# Worth doing anyway so future sessions can use docker without sudo.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER"
fi
