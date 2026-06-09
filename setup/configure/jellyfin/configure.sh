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

mkdir -p ~/library/.config/jellyfin ~/library/media

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
  docker compose -f "$HERE/docker-compose.yml" up -d

# Print the URL the user opens to do first-time setup.
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
if [ -n "$IP" ]; then
  echo
  echo "Jellyfin: http://$IP:8096"
  echo
fi
