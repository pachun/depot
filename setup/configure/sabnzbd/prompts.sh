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
# printf %q on every value: env files get sourced on the next run, so
# any raw character that's special to bash (parens, semicolons, $, etc.
# — all common in passwords) would otherwise blow up at source time.
# %q quotes for re-input by the shell, round-tripping any value safely.
{
  cat <<'EOF'
# Auto-managed by depot's sabnzbd/prompts.sh — edit to rotate
# credentials or change Frugal server topology. Re-run
# setup/configure.sh after edits.

EOF
  printf 'USENET_USERNAME=%q\n' "$USENET_USERNAME"
  printf 'USENET_PASSWORD=%q\n' "$USENET_PASSWORD"
  echo
  printf 'USENET_PRIMARY_HOST=%q\n' "$USENET_PRIMARY_HOST"
  printf 'USENET_PRIMARY_PORT=%q\n' "$USENET_PRIMARY_PORT"
  printf 'USENET_PRIMARY_CONNECTIONS=%q\n' "$USENET_PRIMARY_CONNECTIONS"
  echo
  printf 'USENET_SECONDARY_HOST=%q\n' "$USENET_SECONDARY_HOST"
  printf 'USENET_SECONDARY_PORT=%q\n' "$USENET_SECONDARY_PORT"
  printf 'USENET_SECONDARY_CONNECTIONS=%q\n' "$USENET_SECONDARY_CONNECTIONS"
  echo
  printf 'USENET_BONUS_HOST=%q\n' "$USENET_BONUS_HOST"
  printf 'USENET_BONUS_PORT=%q\n' "$USENET_BONUS_PORT"
  printf 'USENET_BONUS_CONNECTIONS=%q\n' "$USENET_BONUS_CONNECTIONS"
  echo
  cat <<'EOF'
# NZBGeek (or whichever Newznab indexer you use) — picked up by
# prowlarr/configure.sh to register the indexer over the Prowlarr
# REST API. Prowlarr then syncs it to Sonarr / Radarr via the
# Applications wiring.
EOF
  printf 'INDEXER_NZBGEEK_URL=%q\n' "${INDEXER_NZBGEEK_URL:-https://api.nzbgeek.info}"
  printf 'INDEXER_NZBGEEK_API_KEY=%q\n' "${INDEXER_NZBGEEK_API_KEY:-}"
} > "$USENET_ENV"
chmod 600 "$USENET_ENV"
