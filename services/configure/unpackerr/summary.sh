#!/usr/bin/env bash
# unpackerr is a headless daemon — no URL to print. The summary line
# just confirms the container is up and (best-effort) shows how many
# arr targets it picked up at startup so a misconfigured API key is
# visible in the same place every service's status lives.
set -euo pipefail

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^unpackerr$'; then
  echo "Unpackerr:      not running"
  exit 0
fi

# Recent logs include a "Starting Unpackerr" banner that lists
# configured arr instances. Empty target hint (no Sonarr/Radarr lines
# yet) means we ran before sonarr/radarr were initialized — re-run
# configure.sh once they're up.
TARGETS=$(docker logs unpackerr 2>&1 \
  | grep -iE "Sonarr Config|Radarr Config" \
  | tail -4 \
  | sed 's/.*\[INF\] //' \
  | tr '\n' '; ' \
  | sed 's/; $//')

if [ -n "$TARGETS" ]; then
  # echo "Unpackerr:      running ($TARGETS)"
  echo "Unpackerr:      running"
else
  echo "Unpackerr:      running"
fi
