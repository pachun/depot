#!/usr/bin/env bash
# Prompts for everything Prowlarr's configure.sh needs:
#   - admin user/password (shared across all services)
#   - Newznab API key (NZBGeek)
#   - IPTorrents browser session cookie + user-agent
#
# Persists Usenet stuff to usenet.env (shared with sabnzbd's prompts)
# and the IPT stuff to iptorrents.env. Each gets sourced by the
# corresponding configure.sh.
#
# Sourced (not executed) by setup/configure.sh's Phase 1.

HERE_PROMPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE_PROMPTS/../_shared/prompts/admin_credentials.sh"

USENET_ENV="$HOME/hdds/.config/depot/usenet.env"
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
#
# printf %q on every value: env files get sourced on the next run, so
# any raw character that's special to bash (parens, semicolons, $, etc.
# — all common in passwords) would otherwise blow up at source time.
# %q quotes for re-input by the shell, round-tripping any value safely.
umask 077
{
  cat <<'EOF'
# Auto-managed by depot's sabnzbd/prompts.sh and prowlarr/prompts.sh
# — edit to rotate credentials. Re-run setup/configure.sh after
# edits.

EOF
  printf 'USENET_USERNAME=%q\n' "${USENET_USERNAME:-}"
  printf 'USENET_PASSWORD=%q\n' "${USENET_PASSWORD:-}"
  echo
  printf 'USENET_PRIMARY_HOST=%q\n' "${USENET_PRIMARY_HOST:-news.frugalusenet.com}"
  printf 'USENET_PRIMARY_PORT=%q\n' "${USENET_PRIMARY_PORT:-563}"
  printf 'USENET_PRIMARY_CONNECTIONS=%q\n' "${USENET_PRIMARY_CONNECTIONS:-75}"
  echo
  printf 'USENET_SECONDARY_HOST=%q\n' "${USENET_SECONDARY_HOST:-eunews.frugalusenet.com}"
  printf 'USENET_SECONDARY_PORT=%q\n' "${USENET_SECONDARY_PORT:-563}"
  printf 'USENET_SECONDARY_CONNECTIONS=%q\n' "${USENET_SECONDARY_CONNECTIONS:-30}"
  echo
  printf 'USENET_BONUS_HOST=%q\n' "${USENET_BONUS_HOST:-bonus.frugalusenet.com}"
  printf 'USENET_BONUS_PORT=%q\n' "${USENET_BONUS_PORT:-563}"
  printf 'USENET_BONUS_CONNECTIONS=%q\n' "${USENET_BONUS_CONNECTIONS:-50}"
  echo
  printf 'INDEXER_NZBGEEK_URL=%q\n' "$INDEXER_NZBGEEK_URL"
  printf 'INDEXER_NZBGEEK_API_KEY=%q\n' "$INDEXER_NZBGEEK_API_KEY"
} > "$USENET_ENV"
chmod 600 "$USENET_ENV"

# IPTorrents — a tracker that can't be authenticated via API key, only
# a logged-in browser session cookie + the User-Agent that came with
# it. Print copy-paste-friendly instructions; the user fills two
# fields once and depot wires the indexer into Prowlarr.
IPT_ENV="$HOME/hdds/.config/depot/iptorrents.env"

# shellcheck disable=SC1090
[ -f "$IPT_ENV" ] && source "$IPT_ENV"

if [ -z "${IPT_COOKIE:-}" ] || [ -z "${IPT_USERAGENT:-}" ]; then
  cat <<'INSTRUCTIONS'

  ── IPTorrents setup ───────────────────────────────────────────────
  IPTorrents needs a browser session cookie + the User-Agent that
  came with it. Steps:

    1. Open https://iptorrents.com in your browser and log in.
    2. Press F12 to open DevTools. Click the Network tab.
    3. Reload the page (Cmd+R or Ctrl+R).
    4. Click the very first request in the list (the page itself).
    5. In the Headers tab, scroll to "Request Headers".
    6. Copy the value of "Cookie:" and paste below.
    7. After that prompts, do the same for "User-Agent:".
  ───────────────────────────────────────────────────────────────────

INSTRUCTIONS
fi

if [ -z "${IPT_COOKIE:-}" ]; then
  read -r -p "IPTorrents Cookie: " IPT_COOKIE
fi

if [ -z "${IPT_USERAGENT:-}" ]; then
  read -r -p "IPTorrents User-Agent: " IPT_USERAGENT
fi

umask 077
# printf %q on every value — User-Agent strings contain literal parens
# and semicolons (Mozilla/5.0 (X11; …)) that would otherwise read as
# subshell syntax when env is sourced on the next run.
{
  cat <<'EOF'
# Auto-managed by depot's prowlarr/prompts.sh. The cookie expires
# periodically; when IPTorrents searches start failing weeks/months
# later, edit the values here and re-run setup/configure.sh.
EOF
  printf 'IPT_COOKIE=%q\n' "$IPT_COOKIE"
  printf 'IPT_USERAGENT=%q\n' "$IPT_USERAGENT"
} > "$IPT_ENV"
chmod 600 "$IPT_ENV"
