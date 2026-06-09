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

# Print the URL the user opens to do first-time setup. Uses the
# machine's hostname — once tailscale is up (configured by the
# tailscale feature) it resolves via MagicDNS from any tailnet
# device. On the LAN before tailscale is set up, the LAN IP printed
# by ufw's install is the fallback.
echo
echo "Jellyfin: http://$HOSTNAME:8096"
echo
