#!/usr/bin/env bash
# Tailscale auth key — collected up front so configure.sh can call
# `tailscale up --auth-key=...` non-interactively and the user can walk
# away the moment Phase 1 prompts finish. Without a key, configure.sh
# falls back to the browser-auth flow, which prints a URL with a
# few-minute TTL and blocks the install until clicked.
#
# How to get one (mirrors the README):
#   1. https://login.tailscale.com/admin/settings/keys → Generate auth key
#   2. Pick **Reusable** (so a re-install on this NAS doesn't need a new
#      key) + **Ephemeral=off** (so the machine persists in the tailnet
#      across reboots).
#
# Sourced (not executed) by services/configure.sh's Phase 1.

TS_ENV="$HOME/hdds/.config/depot/tailscale.env"
mkdir -p "$(dirname "$TS_ENV")"

# shellcheck disable=SC1090
[ -f "$TS_ENV" ] && source "$TS_ENV"

if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
  cat <<'INSTRUCTIONS'

  ── Tailscale auth key ─────────────────────────────────────────────
  Paste a Tailscale auth key for unattended login. Generate one at
    https://login.tailscale.com/admin/settings/keys
  (Reusable + Ephemeral=off recommended.)

  Leave blank to fall back to the interactive browser auth flow —
  but that URL expires in a few minutes, so don't walk away during
  the tailscale step if you do.
  ───────────────────────────────────────────────────────────────────

INSTRUCTIONS
  read -r -s -p "  Auth key (empty for interactive): " TAILSCALE_AUTH_KEY
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
