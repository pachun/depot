#!/usr/bin/env bash
# Sonarr — TV automation. Sits between prowlarr (search) and
# qbittorrent (download), and manages the library of shows you've
# subscribed to. When a new episode drops, sonarr asks prowlarr to
# search every configured indexer, sends the best grab to qbittorrent,
# then imports/renames the completed file into ~/library/media/shows
# where jellyfin sees it.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p \
  ~/library/.config/sonarr \
  ~/library/downloads \
  ~/library/media/shows

sudo ufw allow 8989/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

cat <<EOF

Sonarr: http://$HOSTNAME:8989
  First run:
  - Authentication: Forms (Login Page) → create a Sonarr admin user
    (separate from your tracker creds).
  - Settings → Media Management → Root Folders → "+" → /shows
  - Settings → Download Clients → "+" → qBittorrent
      Host:     host.docker.internal
      Port:     8080
      Username/Password: what you set in qbittorrent's web UI
      Category: tv (any tag — sonarr uses it to mark downloads)
    Test → Save.
  - Settings → General → Security: copy the API Key.

  Then back in Prowlarr to sync your indexers into Sonarr:
  - Settings → Apps → "+" → Sonarr
      Prowlarr Server: http://host.docker.internal:9696
      Sonarr Server:   http://host.docker.internal:8989
      API Key:         (paste from Sonarr)
      Sync Categories: defaults are fine.
    Test → Save. From now on, every indexer added in Prowlarr
    automatically appears in Sonarr without re-entering credentials.

EOF
