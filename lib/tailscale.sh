#!/usr/bin/env bash
# lib/tailscale.sh — tailscale-serve helpers, sourced by install_depot
# for every service that exposes a UI on the tailnet.
#
# `tailscale serve` runs as a userland forwarder inside tailscaled,
# binding `tailnet-IP:PORT` and proxying to `localhost:LOCAL_PORT` with
# a Let's Encrypt cert tied to the box's tailnet FQDN.

# Print the HTTPS URL at which this box's tailnet exposes a service.
# Output: single URL line, or empty if tailscale isn't authenticated.
# Callers should default to an HTTP fallback when empty.
tailscale_https_url() {
  local port="$1"
  local fqdn
  fqdn=$(tailscale status --json 2>/dev/null \
    | jq -r '.Self.DNSName // empty' \
    | sed 's/\.$//')
  if [ -z "$fqdn" ]; then
    return 0
  fi
  if [ "$port" = "443" ]; then
    echo "https://${fqdn}"
  else
    echo "https://${fqdn}:${port}"
  fi
}

# Expose a local HTTP service as HTTPS on this box's tailnet address.
# Reach it from any tailnet device at:
#   https://<hostname>.<tailnet>.ts.net[:HTTPS_PORT]
#
# Usage: tailscale_serve_https HTTPS_PORT [TARGET_PORT]
#   TARGET_PORT defaults to HTTPS_PORT (typical: service uses the same
#   port for HTTPS that it binds for HTTP).
#
# Idempotent — `tailscale serve` persists its config and re-running
# with the same args is a no-op.
tailscale_serve_https() {
  local https_port="$1"
  local target_port="${2:-$https_port}"
  sudo tailscale serve --bg --https="$https_port" "http://localhost:${target_port}"
}

# Clear all tailscale-serve bindings. Tailscaled binds tailnet-IP:PORT
# for each active serve mapping, and those binds persist across
# container removals. A re-run that recreates a container with the
# matching port (e.g. gluetun publishing 8080 for qBittorrent) fails
# at docker-compose up with "address already in use" — docker wants
# 0.0.0.0:8080 and Linux refuses because the tailnet-IP listener
# already owns it. install_depot calls this once near the top of its
# run so subsequent docker-compose ups don't fight over ports.
#
# Silent no-op when tailscale isn't authenticated (fresh install).
tailscale_serve_reset() {
  sudo tailscale serve reset >/dev/null 2>&1 || true
}
