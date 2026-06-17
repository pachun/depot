#!/usr/bin/env bash
# Shared admin credentials — same username + password used across every
# service's admin user (Jellyfin, qBittorrent, Prowlarr, Sonarr, Radarr,
# Jellyseerr). Single-user box behind tailscale, so the security boundary
# is the tailnet not per-service auth; using one credential pair removes
# the "which password did I use for this app" friction.
#
# Sourced (not executed) by setup/configure.sh's Phase 1 via each
# service's prompts.sh. Re-sourcing is a no-op after the first run —
# the env file holds the answers and the prompts short-circuit.
#
# Lives under _shared/prompts/ — the dispatcher skips directories
# whose basename starts with `_`, so this won't be iterated as a
# feature.

ADMIN_ENV="$HOME/library/.config/depot/admin.env"
mkdir -p "$(dirname "$ADMIN_ENV")"

# shellcheck disable=SC1090
[ -f "$ADMIN_ENV" ] && source "$ADMIN_ENV"

if [ -z "${ADMIN_USERNAME:-}" ]; then
  read -r -p "Admin username: " ADMIN_USERNAME
fi

if [ -z "${ADMIN_PASSWORD:-}" ]; then
  read -r -s -p "Admin password: " ADMIN_PASSWORD
  echo
fi

umask 077
# printf %q on every value: env files get sourced on the next run, so
# any raw character that's special to bash (parens, semicolons, $, etc.
# — all common in passwords) would otherwise blow up at source time.
# %q quotes for re-input by the shell, round-tripping any value safely.
{
  cat <<'EOF'
# Auto-managed by depot's _shared/prompts/admin_credentials.sh. Same
# credentials get pushed to every service's admin user. Edit + re-run
# setup/configure.sh to rotate (services that support API-based
# password change pick it up; Jellyfin needs the old password to
# rotate so handle that there if it ever comes up).
EOF
  printf 'ADMIN_USERNAME=%q\n' "$ADMIN_USERNAME"
  printf 'ADMIN_PASSWORD=%q\n' "$ADMIN_PASSWORD"
} > "$ADMIN_ENV"
chmod 600 "$ADMIN_ENV"
