#!/usr/bin/env bash
# Printed by configure.sh's Phase 3, after every feature has finished
# configuring. Self-contained — re-readable any time as a "where are
# the services?" cheat sheet.
#
# Admin URL is called out separately because Jellyfin's user UI
# doesn't link to it; only the direct path gets you there.
set -euo pipefail
cat <<EOF
Jellyfin:       http://$HOSTNAME:8096
Jellyfin admin: http://$HOSTNAME:8096/web/#/dashboard
EOF
