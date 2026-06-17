#!/usr/bin/env bash
# Wire up qBittorrent as an *arr's torrent download client. Sonarr and
# Radarr both call this from their configure.sh; tvCategory vs.
# movieCategory differ between them (caller passes the appropriate
# one). The other category field is still required by the arr's
# schema, so we send the same value for both — qBit ignores whichever
# one isn't its protocol's typical category.
#
# Idempotent: looks up the existing "qBittorrent" client by name,
# PUTs to update, POSTs to create.
#
# Lives under _shared/arr/ — the dispatcher skips directories whose
# basename starts with `_`, so this file is library code, not a
# feature unit.

# Args:
#   1: arr base URL
#   2: arr API key
#   3: qbit username
#   4: qbit password
#   5: category (e.g. "tv" or "movies")
arr_connect_to_qbit() {
  local base_url="$1"
  local api_key="$2"
  local qbit_user="$3"
  local qbit_pass="$4"
  local category="$5"

  local payload
  payload=$(cat <<EOF
{
  "name": "qBittorrent",
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "implementation": "QBittorrent",
  "implementationName": "qBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host", "value": "host.docker.internal"},
    {"name": "port", "value": 8080},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": ""},
    {"name": "username", "value": $(jq -Rn --arg v "$qbit_user" '$v')},
    {"name": "password", "value": $(jq -Rn --arg v "$qbit_pass" '$v')},
    {"name": "tvCategory", "value": "$category"},
    {"name": "movieCategory", "value": "$category"},
    {"name": "recentTvPriority", "value": 0},
    {"name": "olderTvPriority", "value": 0},
    {"name": "recentMoviePriority", "value": 0},
    {"name": "olderMoviePriority", "value": 0},
    {"name": "initialState", "value": 0}
  ],
  "tags": []
}
EOF
  )

  local existing_id
  existing_id=$(curl -s -H "X-Api-Key: $api_key" \
    "$base_url/api/v3/downloadclient" \
    | jq -r '.[] | select(.name == "qBittorrent") | .id' | head -1)

  local resp
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    local with_id
    with_id=$(echo "$payload" | jq --arg id "$existing_id" '.id = ($id | tonumber)')
    resp=$(curl -s -w $'\n%{http_code}' -X PUT \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$with_id" \
      "$base_url/api/v3/downloadclient/${existing_id}")
    arr_check_response "PUT downloadclient qBittorrent" "$resp"
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$base_url/api/v3/downloadclient")
    arr_check_response "POST downloadclient qBittorrent" "$resp"
  fi
}
