#!/usr/bin/env bash
# Expose a local HTTP service as HTTPS on this box's tailnet address.
# Called from other features' configure.sh so each feature owns the
# decision of "what port am I publishing under" without those features
# needing to know about tailscale internals.
#
# Tailscale terminates TLS using a Let's Encrypt cert tied to this
# box's tailnet FQDN (auto-renewed by tailscaled) and proxies cleartext
# to the local target. Reach it from any tailnet device at:
#
#   https://<hostname>.<tailnet>.ts.net[:HTTPS_PORT]
#
# Usage: expose-https.sh HTTPS_PORT [TARGET_PORT]
#   TARGET_PORT defaults to HTTPS_PORT — typical pattern when a service
#   wants HTTPS on the same port number it already binds for HTTP.
#
# Idempotent — `tailscale serve` persists its config and re-running
# with the same args is a no-op.
#
# Self-installs its dependency on tailscale being up and authenticated;
# safe to call before tailscale's own configure.sh has run in Phase 2.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/configure.sh"

HTTPS_PORT="$1"
TARGET_PORT="${2:-$HTTPS_PORT}"

sudo tailscale serve --bg --https="$HTTPS_PORT" "http://localhost:${TARGET_PORT}"
