#!/usr/bin/env bash
# Tailscale auth key — collected up front so configure.sh can call
# `tailscale up --auth-key=...` non-interactively, and the user can
# walk away the moment Phase 1 prompts finish. Without a key,
# configure.sh falls back to the browser-auth flow.
#
# Sourced (not executed) by services/configure.sh's Phase 1.

TS_ENV="$HOME/hdds/.config/depot/tailscale.env"
mkdir -p "$(dirname "$TS_ENV")"

# shellcheck disable=SC1090
[ -f "$TS_ENV" ] && source "$TS_ENV"

if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
  cat <<'INSTRUCTIONS'

  ── Tailscale auth key ─────────────────────────────────────────────
    1. Open https://login.tailscale.com/admin/settings/keys
    2. Click "Generate auth key"
    3. Set Ephemeral off
    4. Copy the key and paste below
  ───────────────────────────────────────────────────────────────────

INSTRUCTIONS
  read -r -s -p "  Auth key: " TAILSCALE_AUTH_KEY
  echo
fi

umask 077
# printf %q on the value: env files get sourced on the next run, so
# any raw character the key happens to contain that's special to bash
# (unlikely for a Tailscale key, but cheap insurance) round-trips safely.
{
  cat <<'EOF'
# Auto-managed by depot's tailscale/prompts.sh. Edit + re-run
# services/configure.sh to rotate.
EOF
  printf 'TAILSCALE_AUTH_KEY=%q\n' "${TAILSCALE_AUTH_KEY:-}"
} > "$TS_ENV"
chmod 600 "$TS_ENV"

export TAILSCALE_AUTH_KEY
