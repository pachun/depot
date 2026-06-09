#!/usr/bin/env bash
# Radarr — movie automation. Structural twin of sonarr but for movies
# rather than TV. Search-and-grab UX for ad-hoc movie downloads, plus
# automatic naming/organization into ~/library/media/movies/ where
# jellyfin's Movies library picks them up. Doesn't really do
# subscriptions in any useful way (sequels are too rare to matter),
# but the per-download automation alone is worth the setup.
#
# Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/../docker/configure.sh"

mkdir -p \
  ~/library/.config/radarr \
  ~/library/downloads \
  ~/library/media/movies

sudo ufw allow 7878/tcp

sudo \
  PUID="$(id -u)" \
  PGID="$(id -g)" \
  TZ="$(timedatectl show -p Timezone --value)" \
  HOME="$HOME" \
  docker-compose -f "$HERE/docker-compose.yml" up -d

# URL printed by summary.sh in configure.sh's Phase 3.
