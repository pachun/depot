#!/usr/bin/env bash
# Shared first-run auth setup for the *arr stack (Prowlarr, Sonarr,
# Radarr). Each of them exposes a /initialize.json endpoint that's
# anonymous-accessible until the first admin user exists; we POST the
# admin creds there, set auth to "Forms" with local-address bypass,
# and the UI is fully wired without the user ever opening it.
#
# Idempotent: re-running against a server that already has auth
# configured returns 4xx, which we log via the response-check helper
# but treat as "already done, move on."
#
# Underscore-prefixed file at the configure/ root so the dispatcher
# skips it.

# Args:
#   1: base URL (e.g. "http://localhost:9696")
#   2: admin username
#   3: admin password
#   4: label for the response-check log line
arr_initialize_auth() {
  local base_url="$1"
  local username="$2"
  local password="$3"
  local label="$4"

  local resp
  resp=$(curl -s -w $'\n%{http_code}' -X POST \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password" \
    --data-urlencode "passwordConfirmation=$password" \
    --data-urlencode "authenticationMethod=Forms" \
    --data-urlencode "authenticationRequired=DisabledForLocalAddresses" \
    "$base_url/initialize.json")

  local status="${resp##*$'\n'}"

  case "$status" in
    2*)
      # Created successfully.
      return 0
      ;;
    409|404)
      # Auth already initialized OR endpoint unavailable because it's
      # past first-run. Both are "skip, we're already set up."
      return 0
      ;;
    *)
      echo "  WARN: ${label} initialize.json returned HTTP ${status}"
      echo "        ${resp%$'\n'*}" | head -c 400
      echo
      return 1
      ;;
  esac
}
