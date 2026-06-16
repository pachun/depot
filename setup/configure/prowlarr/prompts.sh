#!/usr/bin/env bash
# Prompts for the Newznab indexer API key (NZBGeek) that prowlarr's
# configure.sh registers via API. Persists to the same usenet.env
# file sabnzbd/prompts.sh uses — one secret store for the whole
# Usenet stack.
#
# Sourced (not executed) by setup/configure.sh's Phase 1.

USENET_ENV="$HOME/library/.config/depot/usenet.env"
mkdir -p "$(dirname "$USENET_ENV")"

# shellcheck disable=SC1090
[ -f "$USENET_ENV" ] && source "$USENET_ENV"

: "${INDEXER_NZBGEEK_URL:=https://api.nzbgeek.info}"

if [ -z "${INDEXER_NZBGEEK_API_KEY:-}" ]; then
  read -r -s -p "NZBGeek API key (from nzbgeek.info account → API): " \
    INDEXER_NZBGEEK_API_KEY
  echo
fi

# Re-write the file with the key appended/updated. sabnzbd/prompts.sh
# also writes this file; either ordering of the two prompts.sh calls
# is safe because each one sources the existing file first and merges.
umask 077
{
  # Preserve everything we know about from a prior load of the env.
  # If sabnzbd/prompts.sh has already run this dispatcher session, its
  # values are in scope. If it hasn't yet, the defaults below seed
  # them — sabnzbd/prompts.sh will overwrite when it runs.
  cat <<EOF
# Auto-managed by depot's sabnzbd/prompts.sh and prowlarr/prompts.sh
# — edit to rotate credentials. Re-run setup/configure.sh after
# edits.

USENET_USERNAME=${USENET_USERNAME:-}
USENET_PASSWORD=${USENET_PASSWORD:-}

USENET_PRIMARY_HOST=${USENET_PRIMARY_HOST:-news.frugalusenet.com}
USENET_PRIMARY_PORT=${USENET_PRIMARY_PORT:-563}
USENET_PRIMARY_CONNECTIONS=${USENET_PRIMARY_CONNECTIONS:-75}

USENET_SECONDARY_HOST=${USENET_SECONDARY_HOST:-eunews.frugalusenet.com}
USENET_SECONDARY_PORT=${USENET_SECONDARY_PORT:-563}
USENET_SECONDARY_CONNECTIONS=${USENET_SECONDARY_CONNECTIONS:-30}

USENET_BONUS_HOST=${USENET_BONUS_HOST:-bonus.frugalusenet.com}
USENET_BONUS_PORT=${USENET_BONUS_PORT:-563}
USENET_BONUS_CONNECTIONS=${USENET_BONUS_CONNECTIONS:-50}

INDEXER_NZBGEEK_URL=$INDEXER_NZBGEEK_URL
INDEXER_NZBGEEK_API_KEY=$INDEXER_NZBGEEK_API_KEY
EOF
} > "$USENET_ENV"
chmod 600 "$USENET_ENV"
