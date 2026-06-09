#!/usr/bin/env bash
# Prowlarr — indexer aggregator. Configure your tracker (IPTorrents,
# etc.) credentials here once, then point sonarr and radarr at prowlarr
# and they both inherit every indexer. Without prowlarr you'd be
# pasting the same indexer config into every arr tool separately.
#
# No downloads or media mount — prowlarr only stores indexer configs
# and forwards search queries to sonarr/radarr.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p ~/library/.config/prowlarr

sudo ufw allow 9696/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

cat <<EOF

Prowlarr: http://$HOSTNAME:9696
  First run:
  - Choose "Forms (Login Page)" auth, then create a Prowlarr admin
    user. This is NOT your tracker login — use a fresh username and
    password just for Prowlarr.
  - Settings → General → Security: leave Authentication Required as
    "Enabled" (the default).
  - Indexers → "+" → search "IPTorrents" → fill cookie + user-agent
    (sonarr/radarr inherit this once they're wired up later).

  Getting the IPTorrents cookie + user-agent:
    1. Open https://iptorrents.com in your browser, log in.
    2. DevTools (F12) → Network tab → reload the page.
    3. Click the first request → Headers → Request Headers.
    4. Copy the values of the "Cookie:" and "User-Agent:" lines.
    5. Paste them into Prowlarr's matching fields, Test, Save.
  The cookie expires periodically; when IPTorrents searches start
  failing weeks/months from now, re-grab a fresh cookie the same way.

EOF
