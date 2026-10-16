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

forwarded_port() {
  docker exec gluetun cat /gluetun/forwarded_port 2>/dev/null || true
}

# gluetun pushes each new forwarded port into qBittorrent when the
# port changes, which never happens while qBittorrent is stranded, so
# the rejoined qBittorrent is told the current port here and re-announces
# so trackers learn it is seeding again.
tell_qbittorrent_its_forwarded_port() {
  docker exec gluetun /bin/sh /gluetun/qbit-port-sync.sh "$(forwarded_port)"
  docker exec gluetun wget -qO- --post-data='hashes=all' http://localhost:8080/api/v2/torrents/reannounce >/dev/null
}

is_running gluetun || exit 0
is_running qbittorrent || exit 0

gluetun_started=$(started_at_epoch gluetun)
qbittorrent_started=$(started_at_epoch qbittorrent)

if (( gluetun_started > qbittorrent_started )); then
  echo "gluetun restarted after qBittorrent; restarting qBittorrent so it rejoins gluetun's network namespace"
  docker restart qbittorrent
  tell_qbittorrent_its_forwarded_port
fi
