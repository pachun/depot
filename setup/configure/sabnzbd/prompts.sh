#!/usr/bin/env bash
# Prompts for the Frugal Usenet credentials that sabnzbd's server
# config needs. The provider can't auto-harvest these — they're
# personal — so we ask once and persist to a file outside the repo.
# Re-running setup/configure.sh after the file exists is silent: the
# source-and-check below short-circuits, leaving the user un-bothered.
#
# Sourced (not executed) by setup/configure.sh's Phase 1, which runs
# every feature's prompts.sh up-front so all interactive input
# happens before any actual configure work begins.

USENET_ENV="$HOME/library/.config/depot/usenet.env"
mkdir -p "$(dirname "$USENET_ENV")"

# Load any existing values first so the prompt only fires for missing
# fields — the user can edit the env file by hand to rotate
# credentials later and we won't clobber it.
# shellcheck disable=SC1090
[ -f "$USENET_ENV" ] && source "$USENET_ENV"

# Defaults for the Frugal server topology — the user only ever needs
# to type their account credentials. If their plan ever shifts the
# hostnames, they can edit usenet.env directly.
: "${USENET_PRIMARY_HOST:=news.frugalusenet.com}"
: "${USENET_PRIMARY_PORT:=563}"
: "${USENET_PRIMARY_CONNECTIONS:=75}"

: "${USENET_SECONDARY_HOST:=eunews.frugalusenet.com}"
: "${USENET_SECONDARY_PORT:=563}"
: "${USENET_SECONDARY_CONNECTIONS:=30}"

: "${USENET_BONUS_HOST:=bonus.frugalusenet.com}"
: "${USENET_BONUS_PORT:=563}"
: "${USENET_BONUS_CONNECTIONS:=50}"

if [ -z "${USENET_USERNAME:-}" ]; then
  read -r -p "Frugal Usenet username (newsreader user, not your email): " USENET_USERNAME
fi

if [ -z "${USENET_PASSWORD:-}" ]; then
  read -r -s -p "Frugal Usenet password: " USENET_PASSWORD
  echo
fi

# Persist. umask first so the file is created 600 from the start
# (we still chmod after for safety on existing files).
umask 077
cat > "$USENET_ENV" <<EOF
# Auto-managed by depot's sabnzbd/prompts.sh — edit to rotate
# credentials or change Frugal server topology. Re-run
# setup/configure.sh after edits.

USENET_USERNAME=$USENET_USERNAME
USENET_PASSWORD=$USENET_PASSWORD

USENET_PRIMARY_HOST=$USENET_PRIMARY_HOST
USENET_PRIMARY_PORT=$USENET_PRIMARY_PORT
USENET_PRIMARY_CONNECTIONS=$USENET_PRIMARY_CONNECTIONS

USENET_SECONDARY_HOST=$USENET_SECONDARY_HOST
USENET_SECONDARY_PORT=$USENET_SECONDARY_PORT
USENET_SECONDARY_CONNECTIONS=$USENET_SECONDARY_CONNECTIONS

USENET_BONUS_HOST=$USENET_BONUS_HOST
USENET_BONUS_PORT=$USENET_BONUS_PORT
USENET_BONUS_CONNECTIONS=$USENET_BONUS_CONNECTIONS

# NZBGeek (or whichever Newznab indexer you use) — picked up by
# prowlarr/configure.sh to register the indexer over the Prowlarr
# REST API. Prowlarr then syncs it to Sonarr / Radarr via the
# Applications wiring.
INDEXER_NZBGEEK_URL=${INDEXER_NZBGEEK_URL:-https://api.nzbgeek.info}
INDEXER_NZBGEEK_API_KEY=${INDEXER_NZBGEEK_API_KEY:-}
EOF
chmod 600 "$USENET_ENV"
