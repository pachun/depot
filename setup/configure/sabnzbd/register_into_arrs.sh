#!/usr/bin/env bash
# Register SABnzbd as a download client inside Sonarr or Radarr.
# Sourced (not executed) from sabnzbd/configure.sh, which calls this
# once per arr.
#
# This lives in sabnzbd/ (rather than under _shared/arr/) because SAB
# is the only consumer — the arrs don't pull SAB in during their own
# bootstrap the way they do qBit. SAB pushes itself into the arrs
# during its own configure.sh, so the helper goes with the pusher.
#
# Idempotent: looks up "SABnzbd" by name and PUTs to update, POSTs
# to create. Safe to re-run on every dispatcher invocation.

# Args:
#   1: arr base URL (e.g. "http://localhost:8989")
#   2: api version segment (e.g. "v3")
#   3: arr API key
#   4: SABnzbd API key
#   5: category name to hand SABnzbd ("tv" or "movies")
register_sabnzbd_into_arr() {
  local base_url="$1"
  local api_version="$2"
  local arr_api_key="$3"
  local sabnzbd_api_key="$4"
  local category="$5"

  # SABnzbd config: host.docker.internal because the arr container is
  # reaching SABnzbd's host-published 8085 port. Both arrs already use
  # this same alias for everything else they reach off-container.
  local payload
  payload=$(cat <<EOF
{
  "name": "SABnzbd",
  "enable": true,
  "protocol": "usenet",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "implementation": "Sabnzbd",
  "implementationName": "SABnzbd",
  "configContract": "SabnzbdSettings",
  "fields": [
    {"name": "host", "value": "host.docker.internal"},
    {"name": "port", "value": 8085},
    {"name": "apiKey", "value": "$sabnzbd_api_key"},
    {"name": "username", "value": ""},
    {"name": "password", "value": ""},
    {"name": "tvCategory", "value": "$category"},
    {"name": "movieCategory", "value": "$category"},
    {"name": "recentTvPriority", "value": -100},
    {"name": "olderTvPriority", "value": -100},
    {"name": "recentMoviePriority", "value": -100},
    {"name": "olderMoviePriority", "value": -100},
    {"name": "useSsl", "value": false}
  ],
  "tags": []
}
EOF
  )

  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $arr_api_key" \
    "${base_url}/api/${api_version}/downloadclient" \
    | jq -r '.[] | select(.name=="SABnzbd") | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    curl -s -X PUT \
      -H "X-Api-Key: $arr_api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "${base_url}/api/${api_version}/downloadclient/${existing_id}" >/dev/null
  else
    curl -s -X POST \
      -H "X-Api-Key: $arr_api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base_url}/api/${api_version}/downloadclient" >/dev/null
  fi
}
