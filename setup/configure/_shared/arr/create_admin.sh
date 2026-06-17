#!/usr/bin/env bash
# Create the first admin user on an *arr (Prowlarr, Sonarr, Radarr).
# Each of them exposes a /initialize.json endpoint that's anonymous-
# accessible until the first admin user exists; we POST the admin
# credentials there, set auth to "Forms" with local-address bypass,
# and the UI is fully wired without the user ever opening it.
#
# Idempotent: re-running against a server that already has an admin
# returns 4xx, which we treat as "skip, already set up."
#
# Lives under _shared/arr/ — the dispatcher skips directories whose
# basename starts with `_`, so this file is library code, not a
# feature unit.

# Args:
#   1: base URL (e.g. "http://localhost:9696")
#   2: admin username
#   3: admin password
#   4: label for the response-check log line
arr_create_admin() {
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
    409|404|401)
      # 409: admin already exists.
      # 404: endpoint unavailable because we're past first-run.
      # 401: endpoint exists but now requires auth (Prowlarr does
      #      this once an admin is created — POSTing without auth
      #      gets rejected as unauthorized rather than conflicting).
      # All three mean "already set up, skip."
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
