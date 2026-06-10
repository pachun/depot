#!/usr/bin/env bash
# Print the HTTPS URL at which this box's tailnet exposes a service.
# Called from each feature's summary.sh so the URL output doesn't
# repeat the tailnet-FQDN lookup logic.
#
# Usage: https-url.sh PORT
#
# Output: a single URL line, or nothing if tailscale isn't up /
# authenticated yet. Callers should default to an HTTP fallback when
# this prints nothing (first-run case before tailscale auth).
set -euo pipefail

PORT="$1"

# Self.DNSName is the full tailnet FQDN, returned with a trailing dot.
# Strip the dot. `// empty` makes jq print nothing if Self is missing,
# matching the "tailscale not up yet" path.
FQDN=$(tailscale status --json 2>/dev/null \
  | jq -r '.Self.DNSName // empty' \
  | sed 's/\.$//')

if [ -z "$FQDN" ]; then
  exit 0
fi

if [ "$PORT" = "443" ]; then
  echo "https://${FQDN}"
else
  echo "https://${FQDN}:${PORT}"
fi
