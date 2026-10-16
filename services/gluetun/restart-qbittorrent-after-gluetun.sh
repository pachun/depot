#!/bin/bash
# qBittorrent runs inside gluetun's network namespace. When the gluetun
# container restarts, Docker builds it a fresh namespace, and the
# qBittorrent process is left listening in the orphaned old one: its
# WebUI and peer port stop answering while the container still reports
# healthy. Restarting qBittorrent moves it into gluetun's new namespace.
set -euo pipefail

is_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

started_at_epoch() {
  date -d "$(docker inspect --format '{{.State.StartedAt}}' "$1")" +%s
}

is_running gluetun || exit 0
is_running qbittorrent || exit 0

gluetun_started=$(started_at_epoch gluetun)
qbittorrent_started=$(started_at_epoch qbittorrent)

if (( gluetun_started > qbittorrent_started )); then
  echo "gluetun restarted after qBittorrent; restarting qBittorrent so it rejoins gluetun's network namespace"
  docker restart qbittorrent
fi
